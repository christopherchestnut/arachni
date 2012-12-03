=begin
    Copyright 2010-2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'em-synchrony'
require 'tempfile'

module Arachni

lib = Options.dir['lib']
require lib + 'buffer'
require lib + 'framework'
require lib + 'rpc/server/spider'
require lib + 'rpc/server/module/manager'
require lib + 'rpc/server/plugin/manager'

module RPC
class Server

#
# Wraps the framework of the local instance and the frameworks of all
# its slaves (when it is as Master in High Performance Grid mode) into a neat,
# little, easy to handle package.
#
# Disregard all:
# * 'block' parameters, they are there for internal processing reasons and
#   cannot be accessed via the RPC API.
# * Inherited methods and attributes -- only public methods of this class
#   are accessible over RPC.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Framework < ::Arachni::Framework
    require Options.dir['lib'] + 'rpc/server/distributor'

    include Utilities
    include Distributor

    # Make these inherited methods visible again.
    private :audit_store, :stats, :paused?, :lsmod, :list_modules, :lsplug,
            :list_plugins, :version, :revision, :status, :clean_up!

    public  :audit_store, :stats, :paused?, :lsmod, :list_modules, :lsplug,
            :list_plugins, :lsplug, :version, :revision, :status, :clean_up!

    alias :auditstore   :audit_store

    # Buffer issues and only report them to the master instance when the buffer
    # reaches (or exceeds) this size.
    ISSUE_BUFFER_SIZE = 100

    # How many times to try and fill the issue buffer before flushing it.
    ISSUE_BUFFER_FILLUP_ATTEMPTS = 10

    def initialize( opts )
        super( opts )

        # already inherited but lets make it explicit
        @opts = opts

        # Override standard framework components with their RPC-server
        # counterparts.
        @modules = Module::Manager.new( self )
        @plugins = Plugin::Manager.new( self )
        @spider  = Spider.new( self )

        # holds all running instances
        @instances = []

        # if we're a slave this var will hold the URL of our master
        @master_url = ''

        # some methods need to be accessible over RPC for instance management,
        # restricting elements, adding more pages etc.
        #
        # however, when in HPG mode, the master should not be tampered with,
        # so we generate a local token (which is not known to API clients)
        # to be used server side by self to facilitate access control
        @local_token = gen_token

        @override_sitemap = Set.new
        @local_sitemap    = Set.new

        @element_ids_per_page = {}

        # running slaves
        @running_slaves = Set.new

        # holds instances which have completed their scan
        @done_slaves = Set.new

        @issue_summaries = []
    end

    # @return  [Array<Hash>]  Information about all available plug-ins.
    def list_plugins
        super.map do |plugin|
            plugin[:options] = [plugin[:options]].flatten.compact.map do |opt|
                opt.to_h.merge( 'type' => opt.type )
            end
            plugin
        end
    end
    alias :lsplug :list_plugins

    # @return   [Bool] +true+ If the system is scanning, +false+ if {#run}
    #   hasn't been called yet or if the scan has finished.
    def busy?
        !!@extended_running
    end
    alias :extended_running? :busy?

    #
    # Sets this instance as the master.
    #
    # @return   [Bool]
    #   +true+ on success, +false+ if this instance is not a {#solo? solo} one.
    #
    def set_as_master
        return false if !solo?
        @opts.grid_mode = 'high_performance'
        true
    end

    # @return   [Bool]    true if running in HPG (High Performance Grid) mode
    #                       and instance is the master, false otherwise.
    def master?
        @opts.grid_mode == 'high_performance'
    end
    alias :high_performance? :master?

    # @return   [Bool]  +true+ if this instance is a slave, +false+ otherwise.
    def slave?
        !!@master
    end

    # @return   [Bool]  +true+ if this instance is running solo
    #   (i.e. not a member of a grid operation), +false+ otherwise.
    def solo?
        !master? && !slave?
    end

    #
    # Enslaves another instance and subsequently becomes the master of the group.
    #
    # @param    [Hash]  instance_info   { 'url' => '<host>:<port>', 'token' => 's3cr3t' }
    #
    # @return   [Bool]  +true+ on success, +false+ is this instance is a slave.
    #   Slaves can't have slaves of their own.
    #
    def enslave( instance_info, opts = {}, &block )
        if slave?
            block.call false
            return false
        end

        instance_info = instance_info.to_hash.
            inject( {} ) { |h, (k, v)| h[k.to_s] = v; h }

        fail "Instance info does not contain a 'url' key."   if !instance_info['url']
        fail "Instance info does not contain a 'token' key." if !instance_info['token']

        # since we have slaves we must be a master...
        set_as_master

        instance = connect_to_instance( instance_info )
        instance.opts.set( cleaned_up_opts ) do
            instance.framework.set_master( self_url, token ) do
                @instances << instance_info
                block.call true if block_given?
            end
        end

        true
    end

    #
    # Starts the scan.
    #
    # @return   [Bool]  +false+ if already running, +true+ otherwise.
    #
    def run
        # return if we're already running
        return false if extended_running?

        @extended_running = true

        # prepare the local instance (runs plugins and starts the timer)
        prepare

        #
        # if we're in HPG mode do fancy stuff like distributing and balancing workload
        # as well as starting slave instances and deal with some lower level
        # operations of the local instance like running plug-ins etc...
        #
        # otherwise just run the local instance, nothing special...
        #
        if master?

            ::Thread.new {

                #
                # We're in HPG (High Performance Grid) mode,
                # things are going to get weird...
                #

                # we'll need analyze the pages prior to assigning
                # them to each instance at the element level so as to gain
                # more granular control over the assigned workload
                #
                # put simply, we'll need to perform some magic in order
                # to prevent different instances from auditing the same elements
                # and wasting bandwidth
                #
                # for example: search forms, logout links and the like will
                # most likely exist on most pages of the site and since each
                # instance is assigned a set of URLs/pages to audit they will end up
                # with common elements so we have to prevent instances from
                # performing identical checks.
                #
                # interesting note: should previously unseen elements dynamically
                # appear during the audit they will override these restrictions
                # and each instance will audit them at will.
                #

                # we need to take our cues from the local framework as some
                # plug-ins may need the system to wait for them to finish
                # before moving on.
                sleep( 0.2 ) while paused?

                each = proc do |d_url, iterator|
                    d_opts = {
                        'rank'   => 'slave',
                        'target' => @opts.url,
                        'master' => self_url
                    }

                    connect_to_dispatcher( d_url ).
                        dispatch( self_url, d_opts ) do |instance_hash|
                            enslave( instance_hash ){ |b| iterator.next }
                        end
                end

                after = proc do
                    @status = :crawling

                    spider.on_each_page do |page|
                        update_element_ids_per_page(
                            { page.url => build_elem_list( page ) },
                            @local_token
                        )

                        @local_sitemap << page.url
                    end

                    # start the crawl and extract all paths
                    spider.on_complete do
                        element_ids_per_page = @element_ids_per_page

                        @override_sitemap |= spider.sitemap

                        @status = :distributing

                        # the plug-ins may have updated the page queue
                        # so we need to distribute these pages as well
                        page_a = []
                        while !@page_queue.empty? && page = @page_queue.pop
                            page_a << page
                            @override_sitemap << page.url
                            element_ids_per_page[page.url] |= build_elem_list( page )
                        end

                        # split the URLs of the pages in equal chunks
                        chunks    = split_urls( element_ids_per_page.keys,
                                                @instances.size + 1 )
                        chunk_cnt = chunks.size

                        if chunk_cnt > 0
                            # split the page array into chunks that will be
                            # distributed across the instances
                            page_chunks = page_a.chunk( chunk_cnt )

                            # assign us our fair share of plug-in discovered pages
                            update_page_queue( page_chunks.pop, @local_token )

                            # remove duplicate elements across the (per instance)
                            # chunks while spreading them out evenly
                            elements = distribute_elements( chunks,
                                                            element_ids_per_page )

                            # restrict the local instance to its assigned elements
                            restrict_to_elements( elements.pop, @local_token )

                            # set the URLs to be audited by the local instance
                            @opts.restrict_paths = chunks.pop

                            chunks.each_with_index do |chunk, i|
                                # spawn a remote instance, assign a chunk of URLs
                                # and elements to it and run it
                                distribute_and_run( @instances[i],
                                                   urls:     chunk,
                                                   elements: elements.pop,
                                                   pages:    page_chunks.pop
                                )
                            end
                        end

                        # start the local instance
                        Thread.new {
                            audit

                            @finished_auditing = true

                            cleanup_if_all_done
                        }
                    end

                    spider.update_peers( @instances ){ spider.run }
                end

                # get the Dispatchers with unique Pipe IDs
                # in order to take advantage of line aggregation
                preferred_dispatchers do |pref_dispatchers|
                    iterator_for( pref_dispatchers ).each( each, after )
                end

            }
        else
            # start the local instance
            Thread.new {
                audit

                if slave?
                    # make sure we've reported all issues
                    flush_issue_buffer do
                        @master.framework.slave_done( self_url, master_priv_token ) do
                            @extended_running = false
                        end
                    end
                else
                    @extended_running = false
                    clean_up
                    @status = :done
                end
            }
        end

        true
    end

    #
    # If the scan needs to be aborted abruptly this method takes care of
    # any unfinished business (like signaling running plug-ins to finish).
    #
    # Should be called before grabbing the {#auditstore}, especially when
    # running in HPG mode as it will take care of merging the plug-in results
    # of all instances.
    #
    # You don't need to call this if you've let the scan complete.
    #
    def clean_up( &block )
        if @cleaned_up
            block.call false
            return false
        end
        r = super

        return r if !block_given?

        if @instances.empty?
            block.call( true ) if block_given?
            return
        end

        foreach = proc do |instance, iter|
            instance.framework.clean_up {
                instance.plugins.results do |res|
                    iter.return( !res.rpc_exception? ? res : nil )
                end
            }
        end
        after = proc { |results| @plugins.merge_results( results.compact ); block.call( true ) }
        map_slaves( foreach, after )

        @cleaned_up = true
    end

    # Pauses the running scan on a best effort basis.
    def pause( &block )
        r = super
        return r if !block_given?

        each = proc { |instance, iter| instance.framework.pause { iter.next } }
        each_slave( each, proc { block.call true } )
    end
    alias :pause! :pause

    # Resumes a paused scan right away.
    def resume( &block )
        r = super
        return r if !block_given?

        each = proc { |instance, iter| instance.framework.resume { iter.next } }
        each_slave( each, proc { block.call true } )
    end
    alias :resume! :resume

    #
    # Merged output of all running instances.
    #
    # This is going to be wildly out of sync and lack A LOT of messages.
    #
    # It's here to give the notion of progress to the end-user rather than
    # provide an accurate depiction of the actual progress.
    #
    # The returned object will be in the form of:
    #
    #   [ { <type> => <message> } ]
    #
    # like:
    #
    #   [
    #       { status: 'Initiating'},
    #       {   info: 'Some informational msg...'},
    #   ]
    #
    # Possible message types are:
    # * +status+  -- Status messages, usually to denote progress.
    # * +info+  -- Informational messages, like notices.
    # * +ok+  -- Denotes a successful operation or a positive result.
    # * +verbose+ -- Verbose messages, extra information about whatever.
    # * +bad+  -- Opposite of :ok, an operation didn't go as expected,
    #   something has failed but it's recoverable.
    # * +error+  -- An error has occurred, this is not good.
    # * +line+  -- Generic message, no type.
    #
    # @return   [Array<Hash>]
    #
    def output( &block )
        buffer = flush_buffer

        if @instances.empty?
            block.call( buffer )
            return
        end

        foreach = proc do |instance, iter|
            instance.service.output { |out| iter.return( out ) }
        end
        after = proc { |out| block.call( (buffer | out).flatten ) }
        map_slaves( foreach, after )
    end

    # @see Arachni::Framework#stats
    def stats( *args )
        ss = super( *args )
        ss.tap { |s| s[:sitemap_size] = @local_sitemap.size } if !solo?
        ss
    end

    #
    # Returns aggregated progress data and helps to limit the amount of calls
    # required in order to get an accurate depiction of a scan's progress and includes:
    # * output messages
    # * discovered issues
    # * overall statistics
    # * overall scan status
    # * statistics of all instances individually
    #
    # @param    [Hash]  opts    Options about what data to include:
    # @option opts [Bool] :messages (true) Output messages.
    # @option opts [Bool] :slaves   (true) Slave statistics.
    # @option opts [Bool] :issues   (true) Issue summaries.
    # @option opts [Bool] :stats   (true) Master/merged statistics.
    # @option opts [Bool] :as_hash  (false) If set to +true+, will convert
    #   issues to hashes before returning them.
    #
    # @return    [Hash]  Progress data.
    #
    def progress( opts = {}, &block )
        include_stats    = opts[:stats].nil? ? true : opts[:stats]
        include_messages = opts[:messages].nil? ? true : opts[:messages]
        include_slaves   = opts[:slaves].nil? ? true : opts[:slaves]
        include_issues   = opts[:issues].nil? ? true : opts[:issues]

        as_hash = opts[:as_hash] ? true : opts[:as_hash]

        data = {
            'stats'  => {},
            'status' => status,
            'busy'   => running?
        }

        data['messages']  = flush_buffer if include_messages

        if include_issues
            data['issues'] = as_hash ? issues_as_hash : issues
        end

        data['instances'] = {} if include_slaves

        stats = []
        stat_hash = {}
        stats( true, true ).each { |k, v| stat_hash[k.to_s] = v } if include_stats

        if master? && include_slaves
            data['instances'][self_url] = stat_hash.dup
            data['instances'][self_url]['url'] = self_url
            data['instances'][self_url]['status'] = status
        end

        stats << stat_hash

        if @instances.empty? || !include_slaves
            if include_stats
                data['stats'] = merge_stats( stats )
            else
                data.delete( 'stats' )
            end
            data['instances'] = data['instances'].values if include_slaves
            block.call( data )
            return
        end

        foreach = proc do |instance, iter|
            instance.framework.progress_data( opts ) do |tmp|
                if !tmp.rpc_exception?
                    tmp['url'] = instance.url
                    iter.return( tmp )
                else
                    iter.return( nil )
                end
            end
        end

        after = proc do |slave_data|
            slave_data.compact!
            slave_data.each do |slave|
                data['messages']  |= slave['messages'] if include_messages
                data['issues']    |= slave['issues'] if include_issues

                if include_slaves
                    url = slave['url']
                    data['instances'][url]           = slave['stats'] || {}
                    data['instances'][url]['url']    = url
                    data['instances'][url]['status'] = slave['status']
                end

                stats << slave['stats']
            end

            if include_slaves
                sorted_data_instances = {}
                data['instances'].keys.sort.each do |url|
                    sorted_data_instances[url] = data['instances'][url]
                end
                data['instances'] = sorted_data_instances.values
            end

            if include_stats
                data['stats'] = merge_stats( stats )
            else
                data.delete( 'stats' )
            end

            data['busy']  = slave_data.map { |d| d['busy'] }.include?( true )

            block.call( data )
        end

        map_slaves( foreach, after )
    end
    alias :progress_data :progress

    #
    # Returns the results of the audit as a hash.
    #
    # @return   [Hash]  {AuditStore#to_h}
    #
    # @see AuditStore#to_h
    #
    def report
        audit_store.to_h
    end
    alias :audit_store_as_hash :report
    alias :auditstore_as_hash :report

    # @return   [String]    YAML representation of {#report}.
    def serialized_report
        report.to_yaml
    end

    #
    # Runs a report component and returns the contents of the generated report.
    #
    # Only accepts reports which support an +outfile+ option.
    #
    # @param    [String]    name    Name of the report component to run.
    #
    # @return   [String]    Report content.
    #
    def report_as( name, &block )
        if !reports.available.include?( name.to_s )
            fail Arachni::Exceptions::ComponentNotFound,
                 "Report '#{name}' could not be found."
        end
        if !reports[name].has_outfile?
            fail TypeError, "Report '#{name}' cannot format the audit results as a String."
        end

        outfile = "/#{Dir.tmpdir}/arachn_report_as.#{name}"
        reports.run_one( name, auditstore, 'outfile' => outfile )

        block.call IO.read( outfile )
    ensure
        File.delete( outfile )
    end

    # @return   [String]    YAML representation of {#auditstore}.
    def serialized_auditstore
        audit_store.to_yaml
    end

    # @return  [Array<Arachni::Issue>]  All discovered issues, albeit without any variations.
    def issues
        (auditstore.issues.deep_clone.map do |issue|
            issue.variations.clear
            issue
        end) | @issue_summaries
    end

    #
    # @return   [Array<Hash>]   {#issues} as an array of Hashes.
    #
    # @see #issues
    #
    def issues_as_hash
        issues.map( &:to_h )
    end

    #
    # The following methods need to be accessible over RPC but are *privileged*.
    #
    # They're used for intra-Grid communication between masters and their slaves
    #

    #
    # Restricts the scope of the audit to individual elements.
    #
    # @param    [Array<String>]     elements
    #   List of element IDs (as created by
    #   {Arachni::Element::Capabilities::Auditable#scope_audit_id}).
    #
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  +true+ on success, +false+ on invalid +token+.
    #
    def restrict_to_elements( elements, token = nil )
        return false if master? && !valid_token?( token )
        Element::Capabilities::Auditable.restrict_to_elements( elements )
        true
    end

    #
    # Used by slave crawlers to update the master's list of element IDs per URL.
    #
    # @param    [Hash]     element_ids_per_page
    #   List of element IDs (as created by
    #   {Arachni::Element::Capabilities::Auditable#scope_audit_id}) for each
    #   page (by URL).
    #
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  +true+ on success, +false+ on invalid +token+.
    #
    def update_element_ids_per_page( element_ids_per_page = {}, token = nil,
                                     signal_done_peer_url = nil )
        return false if master? && !valid_token?( token )

        element_ids_per_page.each do |url, ids|
            @element_ids_per_page[url] ||= []
            @element_ids_per_page[url] |= ids
        end

        if signal_done_peer_url
            spider.peer_done signal_done_peer_url
        end

        true
    end

    #
    # Updates the page queue with the provided pages.
    #
    # @param    [Array<Arachni::Page>]     pages   List of pages.
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  +true+ on success, +false+ on invalid +token+.
    #
    def update_page_queue( pages, token = nil )
        return false if master? && !valid_token?( token )
        [pages].flatten.each { |page| push_to_page_queue( page )}
        true
    end

    #
    # Signals that a slave has finished auditing -- each slave must call this
    # when it finishes its job.
    #
    # @param    [String]    slave_url   URL of the calling slave.
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  +true+ on success, +false+ on invalid +token+.
    #
    def slave_done( slave_url, token = nil )
        return false if master? && !valid_token?( token )
        @done_slaves << slave_url

        cleanup_if_all_done
        true
    end

    #
    # Registers an array holding {Arachni::Issue} objects with the local instance.
    #
    # Used by slaves to register the issues they find.
    #
    # @param    [Array<Arachni::Issue>]    issues
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  +true+ on success, +false+ on invalid +token+.
    #
    def register_issues( issues, token = nil )
        return false if master? && !valid_token?( token )
        @modules.class.register_results( issues )
        true
    end

    #
    # Registers an array holding stripped-out {Arachni::Issue} objects
    # with the local instance.
    #
    # Used by slaves to register their issues (without response bodies and other
    # largish data sets) with the master right away while buffering the complete
    # issues to be transmitted in batches later for better bandwidth utilization.
    #
    # These summary issues are to be included in {#issues} in order for the master
    # to have accurate live data to present to the client.
    #
    # @param    [Array<Arachni::Issue>]    issues
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  +true+ on success, +false+ on invalid +token+.
    #
    def register_issue_summaries( issues, token = nil )
        return false if master? && !valid_token?( token )
        @issue_summaries |= issues
        true
    end

    #
    # Sets the URL and authentication token required to connect to the
    # instance's master.
    #
    # @param    [String]    url     Master's URL in +hostname:port+ form.
    # @param    [String]    token   Master's authentication token.
    #
    # @return   [Bool]  +true+ on success, +false+ if the current instance is
    #   already part of the grid.
    #
    def set_master( url, token )
        return false if !solo?

        # make sure the desired plugins are loaded before #prepare runs them
        plugins.load @opts.plugins if @opts.plugins

        prepare

        @master_url = url
        @master = connect_to_instance( 'url' => url, 'token' => token )

        @slave_element_ids_per_page ||= {}

        @elem_ids_filter ||= Arachni::BloomFilter.new

        spider.on_each_page do |page|
            @status = :crawling

            @local_sitemap << page.url

            ids = build_elem_list( page ).reject do |id|
                if @elem_ids_filter.include? id
                    true
                else
                    @elem_ids_filter << id
                    false
                end
            end

            next if ids.empty?

            @slave_element_ids_per_page[page.url] = ids.map { |i| i }
        end

        spider.after_each_run do
            if !@slave_element_ids_per_page.empty?
                @master.framework.
                    update_element_ids_per_page( @slave_element_ids_per_page.dup,
                                               master_priv_token,
                                               spider.done? ? self_url : false ){}

                @slave_element_ids_per_page.clear
            else
                spider.signal_if_done( @master )
            end
        end

        # buffers logged issues that are to be sent to the master
        @issue_buffer = Buffer::AutoFlush.new( ISSUE_BUFFER_SIZE,
                                               ISSUE_BUFFER_FILLUP_ATTEMPTS )

        @issue_buffer.on_flush { |buffer| send_issues_to_master( buffer ) }

        # don't store issues locally
        @modules.do_not_store

        @modules.on_register_results do |issues|
            # Only send summaries of the issues to the master right away so that
            # the the master will have live data to show the user...
            send_issue_summaries_to_master issues

            # ...but buffer the complete issues to be sent in batches for better
            # bandwidth utilization.
            @issue_buffer.batch_push issues
        end
        true
    end

    # @return   [String]    URL of this instance.
    def self_url
        @self_url ||= "#{@opts.rpc_address}:#{@opts.rpc_port}"
    end

    # @return   [String]    This instance's RPC token.
    def token
        @opts.datastore[:token]
    end

    private

    def prepare
        return if @prepared
        super
        @prepared = true
    end

    def cleanup_if_all_done
        return if !@finished_auditing || @running_slaves != @done_slaves

        # we pass a block because we want to perform a grid cleanup,
        # not just a local one
        clean_up do
            @extended_running = false
            @status = :done
        end
    end

    def auditstore_sitemap
        @override_sitemap | @sitemap
    end

    def valid_token?( token )
        @local_token == token
    end

    #
    # Reports an array of issues back to the master instance.
    #
    # @param    [Array<Arachni::Issue>]     issues
    #
    def report_issues_to_master( issues )
        @issue_buffer.batch_push issues
        true
    end

    def flush_issue_buffer( &block )
        send_issues_to_master( @issue_buffer.flush ){ block.call if block_given? }
    end

    def send_issues_to_master( issues, &block )
        @master.framework.register_issues( issues,
                                           master_priv_token
        ){ block.call if block_given? }
    end

    def send_issue_summaries_to_master( issues, &block )
        @unique_issue_summaries ||= Set.new

        # Multiple variations for grep modules are not being filtered when
        # an issue is registered, and for good reason; however, we do need to filter
        # them in this case since we're summarizing.
        summaries = AuditStore.new( issues: issues ).issues.map do |i|
            next if @unique_issue_summaries.include?( i.unique_id )
            di = i.deep_clone
            di.variations.clear
            di
        end.compact

        @unique_issue_summaries |= summaries.each { |issue| issue.unique_id }

        @master.framework.register_issue_summaries( summaries,
                                           master_priv_token
        ){ block.call if block_given? }
    end

    def master_priv_token
        @opts.datastore['master_priv_token']
    end

    def gen_token
        Digest::SHA2.hexdigest( 10.times.map{ rand( 9999 ) }.join )
    end

end

end
end
end
