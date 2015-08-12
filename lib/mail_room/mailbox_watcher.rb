module MailRoom
  # split up between processing and idling?
  class MailboxWatcher
    attr_accessor :idling_thread

    def initialize(mailbox)
      @mailbox = mailbox
      @done_lock = Mutex.new
      @running = false
      @logged_in = false
      @idling = false
    end

    def imap
      wlog("S1", "")
      @imap ||= Net::IMAP.new('imap.gmail.com', :port => 993, :ssl => true)
      wlog("S2", "")
      tries = 0
      while (@imap == nil) && (tries < 10) do
        sleep(10)
        wlog("EMPTY IMAP", "")
        @imap ||= Net::IMAP.new('imap.gmail.com', :port => 993, :ssl => true)
      end
      if @imap == nil then
        raise "IMAP"
      end
      @imap
    end

    def handler
      #wlog("S3", @mailbox)
      wlog("S3", "")
      @handler ||= MailboxHandler.new(@mailbox, imap)
      #wlog("S4", @mailbox)
      wlog("S4", "")
      @handler
    end

    def running?
      @running
    end

    def logged_in?
      @logged_in
    end

    def idling?
      @idling
    end

    def setup
      log_in
      set_mailbox
    end

    def log_in
      if @mailbox != nil then
        #wlog("S5", @mailbox.email + "---" + @mailbox.password)
        wlog("S5", "")
      end
      imap.login(@mailbox.email, @mailbox.password)
      if @mailbox != nil then
        #wlog("S6", @mailbox.email + "---" + @mailbox.password)
        wlog("S6", "")
      end
      # To see what mailboxes ('name' config param) are available to map
      # x = imap.list('*', '*')
      # `echo "#{x}" > /tmp/avail_folders`
      @logged_in = true
    end

    def set_mailbox
      if @mailbox != nil then
        wlog("S7", @mailbox.name)
      end
      res = imap.select(@mailbox.name) if logged_in?
      if @mailbox != nil then
        wlog("S8", @mailbox.name)
      end
      res
    end

    # log stuff for debugging.
    def wlog(state, msg="")
      #if false then
      watchfile = @mailbox.state_watcher
      if true then
        `echo "#{Time.now} #{state} #{msg}" >> "#{watchfile}"`
      end
    end

    def reset_imap(where, msg)
      wlog("RESET", msg)
      if imap.disconnected? then
        wlog("DISCONNECTED", msg)
      else
        wlog("BROKEN", msg)
        # We don't want to try idle_done since if we're not in idle state, this will
        # throw an exception.  There aren't a lot of primitives available; disconnect is the only
        # other thing to try.
        if msg == "deadlock detected" then
          wlog("DEADLOCK", msg)
          `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
          raise "WATCHER"
        end
        begin
          imap.disconnect
        rescue Exception => e
          wlog("PANIC", e)
          `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
          raise "WATCHER"
        end
      end
      begin
        @imap = nil
        @logged_in = false
        @handler = nil
        @idling = false  # prevent watchdogs
        setup
      rescue Exception => e
        wlog("FATAL", e)
        `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
        raise "WATCHER" # kills thread
      end
    end

    def idle
      return unless logged_in?

      begin
        clean = true

        begin
          wlog("c", "")
          # We can't really protect idle from a disconnect caused by an exception in the main watchdog process.
          # Presumably, if this happens, we'll get an exception if the idle is attempted prior to the idle command.
          # The mutex only serves to protect against an idle_done at the wrong time, and since idle_done itself doesn't block
          # we can use mutex to protect it.
          @idling = true

          while (@imap == nil) || imap.disconnected? do
            wlog("waiting for imap", "")
            sleep(1)
          end

          imap.idle do |response|
            wlog("y", "")
            if response.respond_to?(:name) && response.name == 'EXISTS'
              # yield a response -- there's mail to read.  Still in idle state, so set to done
              # so we can cleanly re-enter idle (it's an error to idle while in idle state).
              wlog("E", "")
              @done_lock.lock
              if @idling then
                imap.idle_done
                @idling = false
              end
              @done_lock.unlock
            else
              # We may get here if the watchdog forces an idle_done.
              # In this case, we don't want another idle_done (which will cause an error).
              # We simply return, and process_messages will find nothing to do; we'll end up back in idle.
              wlog("X", "")
            end  # imap.idle
          end
          wlog("c1", "")
        rescue Exception => e
          wlog("E2", e)
          clean = false
          reset_imap("idle", e)
        end

      end while !clean

      @idling = false

    end

    def process_mailbox
      handler.process
    end

    def stop_idling
      return unless idling?

      imap.idle_done
      idling_thread.join
    end

    # http://ruby-doc.org/stdlib-1.9.3/libdoc/net/imap/rdoc/Net/IMAP.html
    def run
      setup

      @running = true

      process_mailbox  # idle won't find anything if no new mail has arrived.  So check first to see
                       # if we have stuff to pick up.  All idle does is wake up if new mail has arrived.

      self.idling_thread = Thread.start do
        while (running?) do
          # block until we stop idling
          wlog("i", "")
          idle     # when idle returns, new messages are ready or idle got somehow interrupted.
          wlog("p", "")
          begin
            if (@imap != nil) && !imap.disconnected? then
              wlog("pr", "")

              process_mailbox

              wlog("pr_done", "")
            end
          rescue Exception => e
            reset_imap("thread", e)
          end
        end
      end

      # Main program; watches over the thread.
      # Note that idle_done is the only available primitive to try to reset things.
      # disconnect in the middle of an idle appears fatal but might be worth another look.
      # kill must use -9 if we're in the middle of an idle to nuke the whole process.
      # kill -INT only works if disconnected.
      loop do
        sleep(60 * 10)  # imap times out after 29 min so 10 should be conservative
        wlog("a", "")
        if @idling then  ### this might need to be in a critical section.
          begin
            # force keepalive; thread will then idle again.
            @done_lock.lock
            if @idling then
              wlog("POKE_TRY", "")
              if (@imap != nil) && !imap.disconnected? then
                wlog("POKED", "")
                imap.idle_done
              end
              @idling = false
            end
            @done_lock.unlock
          rescue Exception => e
            reset_imap("watchdog", e)
          end
        end
        wlog("b", "")
      end
    end

    def quit
      @running = false
      stop_idling
    end

  end # class

end # module
