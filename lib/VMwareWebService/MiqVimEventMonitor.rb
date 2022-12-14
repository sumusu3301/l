require 'VMwareWebService/logging'
require 'VMwareWebService/MiqVimInventory'

class MiqVimEventMonitor < MiqVimInventory
  include VMwareWebService::Logging

  def initialize(server:, username:, password:, port: 443, ssl_options: {}, event_filter_spec: nil, page_size: 100, max_wait: 60)
    super(:server => server, :port => port, :ssl_options => ssl_options, :username => username, :password => password, :cache_scope => :cache_scope_event_monitor)

    @eventFilterSpec = event_filter_spec || VimHash.new("EventFilterSpec")
    @pgSize          = page_size
    @maxWait         = max_wait
    @_monitorEvents  = true
    @emPropCol       = nil

    hostSystemsByMor
    # datacentersByMor
    virtualMachinesByMor
    # dataStoresByMor
  end # def initialize

  def monitorEvents
    raise "monitorEvents: no block given" unless block_given?

    eventHistoryCollector = createCollectorForEvents(@sic.eventManager, @eventFilterSpec)
    setCollectorPageSize(eventHistoryCollector, @pgSize)

    pfSpec = VimHash.new("PropertyFilterSpec") do |pfs|
      pfs.propSet = VimArray.new("ArrayOfPropertySpec") do |psa|
        psa << VimHash.new("PropertySpec") do |ps|
          ps.type = eventHistoryCollector.vimType
          ps.all = "false"
          ps.pathSet = "latestPage"
        end
      end
      pfs.objectSet = VimArray.new("ArrayOfObjectSpec") do |osa|
        osa << VimHash.new("ObjectSpec") do |os|
          os.obj = eventHistoryCollector
        end
      end
    end

    filterSpecRef = nil

    begin
        @emPropCol = @sic.propertyCollector
        filterSpecRef = createFilter(@emPropCol, pfSpec, "true")

        version = nil
        begin
            while @_monitorEvents
              updateSet = waitForUpdatesEx(@emPropCol, version, :max_wait => @maxWait)
              next if updateSet.nil?

              version = updateSet.version

              next if updateSet.filterSet.nil? || updateSet.filterSet.empty?
              fu = updateSet.filterSet[0]
              next if fu.filter != filterSpecRef
              objUpdate = fu.objectSet[0]
              next if objUpdate.kind != ObjectUpdateKind::Modify
              next if objUpdate.changeSet.empty?

              changeSetAry = []
              objUpdate.changeSet.each do |propChange|
                next unless propChange.name =~ /latestPage.*/
                next unless propChange.val
                if propChange.val.kind_of?(Array)
                  propChange.val.each { |v| changeSetAry << fixupEvent(v) }
                else
                  changeSetAry << fixupEvent(propChange.val)
                end
              end
              yield changeSetAry
            end
          rescue HTTPClient::ReceiveTimeoutError => terr
            retry if isAlive?
            logger.debug "MiqVimEventMonitor.monitorEvents: connection lost"
            raise
          end
      rescue SignalException => err
      ensure
        logger.info "MiqVimEventMonitor: calling destroyPropertyFilter"
        destroyPropertyFilter(filterSpecRef) if filterSpecRef
        logger.info "MiqVimEventMonitor: returned from destroyPropertyFilter"
        disconnect
      end
  end # def monitorEvents

  def stop
    logger.info "MiqVimEventMonitor stopping..."
    @_monitorEvents = false
    if @emPropCol
      logger.info "MiqVimEventMonitor: calling cancelWaitForUpdates"
      cancelWaitForUpdates(@emPropCol)
      logger.info "MiqVimEventMonitor: returned from cancelWaitForUpdates"
    end
  end

  # The set of events for which fixupEvent should add a VM
  ADD_VM_EVENTS = ['VmCreatedEvent', 'VmClonedEvent', 'VmDeployedEvent', 'VmRegisteredEvent']

  def fixupEvent(event)
    unless event.kind_of?(Hash)
      logger.error "MiqVimEventMonitor.fixupEvent: Expecting Hash, got #{event.class}"
      if event.kind_of?(Array)
        event.each_index do |i|
          logger.error "MiqVimEventMonitor.fixupEvent: event[#{i}] is a #{event[i].class}"
          logger.error "\tMiqVimEventMonitor.fixupEvent: event[#{i}] = #{event[i].inspect}"
        end
      else
        logger.error "\tMiqVimEventMonitor.fixupEvent: event = #{event.inspect}"
      end
      raise "MiqVimEventMonitor.fixupEvent: Expecting Hash, got #{event.class}"
    end

    event['eventType'] = event.xsiType.split("::").last
    @cacheLock.synchronize(:SH) do
      ['vm', 'sourceVm', 'srcTemplate'].each do |vmStr|
        next unless (eventVmObj = event[vmStr])
        addVirtualMachine(eventVmObj['vm']) if ADD_VM_EVENTS.include?(event['eventType'])
        next unless (vmObj = virtualMachinesByMor_locked[eventVmObj['vm']])

        eventVmObj['path'] = vmObj['summary']['config']['vmPathName']
        eventVmObj['uuid'] = vmObj['summary']['config']['uuid'].presence

        removeVirtualMachine(eventVmObj['vm']) if event['eventType'] == 'VmRemovedEvent'
      end
    end
    et = event['eventType']
    if et == 'VmRelocatedEvent' || et == 'VmMigratedEvent' || et == 'DrsVmMigratedEvent' || et == 'VmResourcePoolMovedEvent' ||
       (et == 'TaskEvent' && event['info']['name'] == 'MarkAsVirtualMachine')
      vmMor = event['vm']['vm']
      removeVirtualMachine(vmMor)
      addVirtualMachine(vmMor)
    end
    (event)
  end

  def monitorEventsToStdout
    monitorEvents do |ea|
      ea.each do |e|
        puts
        puts "*** New Event: #{e['eventType']}"
        dumpObj(e)
        # doEvent(e)
      end
    end
  end

  def monitorEventsTest
    monitorEvents do |ea|
      ea.each do |e|
        puts e['message'] if e['message']
      end
    end
  end

  #
  # Test: prevent clone of VM: rpo-clone-src
  #
  def doEvent(e)
    return if e['eventType'] != "TaskEvent"
    return if e['info']['name'] != "CloneVM_Task"
    return if e['vm']['name'] != "rpo-clone-src"
    begin
      cancelTask(String.new(e['info']['task'].to_str))
    rescue => err
      logger.error err.to_s
      logger.error err.backtrace.join("\n")
    end
  end
end # module MiqVimEventMonitor
