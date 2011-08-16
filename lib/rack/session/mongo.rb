require 'rubygems'
require 'mongo'
require 'rack/session/abstract/id'

module Rack
  module Session
    # Implements the +Rack::Session::Abstract::ID+ session store interface
    #
    # Cookies sent to the client for maintaining sessions will only contain an
    # id reference. See {Rack::Session::Mongo#initialize below} for options.
    #
    # == Usage Example
    #
    #     use Rack::Session::Mongo, :connection => @existing_mongodb_connection;,
    #                               :expire_after => 1800
    class Mongo < Abstract::ID
      attr_reader :mutex, :pool, :connection, :marshal_data
      DEFAULT_OPTIONS = Abstract::ID::DEFAULT_OPTIONS.merge :db => 'rack', :collection => 'sessions', :drop => false
      
      # Creates a new Mongo session store pool. You probably won't initialize
      # it his way. See the overview for standard usage instructions.
      #
      # Unless specified, the options can be set on a per request basis, in the
      # +rack.session.options+ environment hash. Additionally the id of
      # the session can be found within the options hash at the key +:id+. It is
      # highly not recommended to change its value.
      #
      # @param app a Rack application
      # @param [Hash] options configuration for the session pool
      # @option options [Mongo::Connection] :connection (Mongo::Connection.new)
      #   used to create the pool. Change this if you already have a connection
      #   setup, or want to connect to a server other than +localhost+.
      #   — <i>pool instance global</i>
      # @option options [String] :db ('rack') the Mongo db to use — <i>pool
      #   instance global</i>
      # @option options [String] :collection ('sessions') the Mongo collection
      #   to use. — <i>pool instance global</i>
      # @option options [boolean] :marshal_data (true) Marshal data into string 
      #   otherwise store as hash in db. — <i>pool instance global</i>
      #   Note:  if you use this then the keys used to lookup values must be strings
      #          even if you put in symbols.  *Example:* 
      #       request1: session[:test] = true
      #       request2: session[:test]
      #             > nil
      #                 session['test']
      #             > true
      # 
      #      The advantage is that you can query the contents of the sessions and 
      #      potentially make changes on the fly
      # @option options [Integer] :expire_after (nil) the time in seconds for
      #   the session to last for. *Example:* If this is set to +1800+, the
      #   session will be deleted if the client doesn't make a request within 30
      #   minutes of its last request.
      # @option options [Integer] :clear_expired_after (1800) the time in seconds
      #   before we clear out old sessions. *Example:* If this is set to +1800+, the
      #   the session will be cleared from mongodb when a session is requested, if
      #   it has been 1800 seconds since it was last cleared.  setting to -1 will 
      #   disable this.
      # @option options [true, false] :defer (false) don't set the session
      #   cookie for this request.
      # @option options [true, false] :renew (false) causes the generation of
      #   a new session id, and migrates the data to id. Overrides +:defer+.
      # @option options [true, false] :drop (false) destroys the current
      #   session, and creates a new one.
      # @option options [String] :key ('rack.session') the name of the cookie
      #   that stores the session id
      # @option options [String] :path ('/') the cookie path
      # @option options [String] :domain (nil) the cookie domain
      # @option options [true, false] :secure (false) the cookie security flag;
      #   tells the client to only send the cookie over HTTPS.
      # @option options [true, false] :httponly (true) the cookie HttpOnly flag;
      #   makes the cookie invisible to client-side Javascript.
      def initialize(app, options = {})
        super
        @mutex = Mutex.new
        @connection = @default_options[:connection] || ::Mongo::Connection.new
        @pool = @connection.db(@default_options[:db]).collection(@default_options[:collection])
        @pool.create_index([['expires', -1]])
        @pool.create_index('sid', :unique => true)
        @marshal_data = @default_options[:marshal_data].nil? ? true : @default_options[:marshal_data] == true
        @next_expire_period = nil
        @recheck_expire_period = @default_options[:clear_expired_after].nil? ? 1800 : @default_options[:clear_expired_after].to_i
      end
      
      def get_session(env, sid)
        @mutex.lock if env['rack.multithread']
        session = find_session(sid) if sid
        unless sid and session
          env['rack.errors'].puts("Session '#{sid}' not found, initializing...") if $VERBOSE and not sid.nil?
          session = {}
          sid = generate_sid
          save_session(sid)
        end
        session.instance_variable_set('@old', {}.merge(session))
        session.instance_variable_set('@sid', sid)
        return [sid, session]
      ensure
        @mutex.unlock if env['rack.multithread']
      end
      
      def set_session(env, sid, new_session, options)
        @mutex.lock if env['rack.multithread']
        expires = Time.now + options[:expire_after] if !options[:expire_after].nil?
        session = find_session(sid) || {}
        if options[:renew] or options[:drop]
          delete_session(sid)
          return false if options[:drop]
          sid = generate_sid
          save_session(sid, session, expires)
        end
        old_session = new_session.instance_variable_get('@old') || {}
        session = merge_sessions(sid, old_session, new_session, session)
        save_session(sid, session, expires)
        return sid
      ensure
        @mutex.unlock if env['rack.multithread']
      end
      
      private

        def generate_sid
          loop do
            sid = super
            break sid unless find_session(sid)
          end
        end
        
        def find_session(sid)
          time = Time.now
          if @recheck_expire_period != -1 && (@next_expire_period.nil? || @next_expire_period < time)
            @next_expire_period = time + @recheck_expire_period
            @pool.remove :expires => {'$lte' => time} # clean out expired sessions 
          end
          session = @pool.find_one :sid => sid
          #if session is expired but hasn't been cleared yet.  don't return it.
          if session && session['expires'] != nil && session['expires'] < time
            session = nil
          end
          session ? unpack(session['data']) : false
        end
        
        def delete_session(sid)
          @pool.remove :sid => sid
        end
        
        def save_session(sid, session={}, expires=nil)
          @pool.update({:sid => sid}, {"$set" => {:data => pack(session), :expires => expires}}, :upsert => true)
        end
        
        def merge_sessions(sid, old, new, current=nil)
          current ||= {}
          unless Hash === old and Hash === new
            warn 'Bad old or new sessions provided.'
            return current
          end
          # delete keys that are not in common
          delete = current.keys - (new.keys & current.keys)
          warn "//@#{sid}: dropping #{delete*','}" if $DEBUG and not delete.empty?
          delete.each{|k| current.delete k }

          update = new.keys.select{|k| !current.has_key?(k) || new[k] != current[k] || new[k].kind_of?(Hash) || new[k].kind_of?(Array) }    
          warn "//@#{sid}: updating #{update*','}" if $DEBUG and not update.empty?
          update.each{|k| current[k] = new[k] }

          current
        end
      
        def pack(data)
          if(@marshal_data)
            [Marshal.dump(data)].pack("m*")
          else
            data
          end
        end

        def unpack(packed)
          return nil unless packed
          if(@marshal_data)
            Marshal.load(packed.unpack("m*").first)
          else
            packed
          end
        end
    end
  end
end
