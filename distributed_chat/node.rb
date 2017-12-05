#!/usr/bin/env ruby
# encoding: utf-8

require "bunny"
require "json"
require 'thread'

module DistributedChat
  class Node
    attr_accessor :users, :state, :is_leader, :silenced
    attr_reader   :user_name, :start_time, :leader_present,
                  :bunny_connection, :channel, :exchange, :queue

    STATE_CONNECTING = 'connecting'
    STATE_CONNECTED = 'connected'
    STATE_DONE = 'done'

    CONNECT_WAIT_TIME = 2
    DEBUG_LEVEL = 0

    def initialize(user_name)
      @user_name = user_name
      @state = STATE_CONNECTING
      @is_leader = false
      @users = {}
      @start_time = Time.now.to_i
      @bunny_connection = Bunny.new
      @bunny_connection.start

      @channel = @bunny_connection.create_channel(nil, 16)
      @exchange = @channel.fanout("chat.main")

      @leader_present = false
      @lock = Mutex.new
    end

    def run
      begin 
        @channel.queue(user_name, :auto_delete => true, :block => false).bind(@exchange).subscribe do |delivery_info, properties, body|
          info = JSON.parse(body)
          debug "=====> Got msg! #{info}", 1
          handle_incoming_info(info)
        end

        request_roll_call
        complete_connection

        puts " [*] To exit press CTRL+C"
        puts "connecting..."

        enter_chat_loop
        exit_program

      rescue Interrupt => _
        exit_program
      end
    end

    private

      def complete_connection
        thr = Thread.new do
          debug("in Complete_connection. about to sleep for #{CONNECT_WAIT_TIME}")
          sleep(CONNECT_WAIT_TIME)
          debug "after Sleep #{CONNECT_WAIT_TIME}"
          debug ("users = #{users}. user_name = '#{user_name}'")
          if users[user_name]
            puts "ERROR! name #{user_name} is already taken. Please choose another!"
            exit_program
            exit
          end

          debug "users = #{users}", 1

          if users.keys.size == 0
            self.is_leader = true
          end
          self.state = STATE_CONNECTED
          #passing in true to indicate this is the first time user is announcing
          announce_self(true)
          #make sure we add self to users list
          add_to_users( 'name' => user_name, 'start_time' => start_time, 'is_leader' => is_leader)
          num_users = users.keys.size
          puts "Connected!  there #{num_users == 1 ? 'is' : 'are'} #{num_users} #{num_users == 1 ? 'user' : 'users'} online. #{is_leader ? ' You are now the leader!' : ''}"
          debug "users: #{users}"
        end
      end

      def enter_chat_loop
        while ( (line=STDIN.gets).chomp != 'bye' && state != STATE_DONE)
          valid_line = true
          type = 'message'
          target = nil
          if (line.start_with?("\\"))
            type = "command"
          elsif (line.start_with?("\!"))
            type = "directive"
            vals = line.match(/^!(\w+)\s+(\w+)/)
            if (vals && vals[1] && vals[2])
              line = vals[1]
              target = vals[2]
            else
              valid_line = false
            end
          end
          if (silenced)
            puts "Sorry. The leader has silenced you!"
          else
            if (valid_line)
              msg = { name: user_name, type: type, message: line, target: target }.to_json
              publish(msg)
            else
              puts "Invalid line: #{line}"
            end
          end
        end
      end

      #process all incoming messages
      def handle_incoming_info(info)
        type = info['type']
        other_user_name = info['name']
        same_user = is_same_user?(other_user_name)
        case type
        when 'message'
          puts "[#{info['name']}]: #{info['message']}" unless same_user
        when 'announce'
          if (info['state'] == 'connected')
            add_to_users(info)
            puts "[!] #{other_user_name} has entered chat" if (!same_user && info['first_time'])
          end
        when 'directive'
          directive = info['message']
          case directive
          when 'roll_call'
            announce_self
          when 'silence'
            if (sent_by_leader?(info) && info['target'] == user_name)
              self.silenced = true
              puts "[!] You have been silenced!"
            end
          when 'unsilence'
            if (sent_by_leader?(info) && info['target'] == user_name)
              self.silenced = false
              puts "[!] You have been unsilenced"
            end
          when 'remove'
            if (sent_by_leader?(info) && info['target'] == user_name)
              puts "You have been kicked out by leader #{info['name']}"
              self.state = STATE_DONE
              exit_program
              exit 
            end
          else
            if (same_user)
              puts "Invalid directive #{directive}"
            end
          end
        when 'command'
          command = info['message'].chomp
          case command
          when '\list_users'
            puts "[#{user_name}]: users: #{users}" if same_user
          when '\is_leader'
            puts "[#{user_name}] is_leader: #{is_leader}" if same_user
          when '\state'
            puts "[#{user_name}] state: #{state}" if same_user
          when '\current_leader'
            display_current_leader if same_user
          else
            if (same_user)
              puts "[#{user_name}] Unknown command: #{command}"
            end
          end
        when 'leave'
          if (!is_same_user?(other_user_name))
            puts "[!] #{info['name']} left chat"
            remove_from_users(other_user_name)
          end
        when 'election'
          election = info['message']
          case election
          when 'announce'
            #start a new electiion
            if (!same_user)
              debug "about to do_election!!!. state = #{state}", 2
              do_election(info['election_start_time']) if state == STATE_CONNECTED
            end
          when 'alive'
            add_to_users(info)
          when 'victory'
            #set new leader
            debug "NEW LEADER = #{other_user_name}", 2
            self.users[other_user_name][:is_leader] = true
          else
            #warn "Invalid election message #{election}"
          end
        else
          #put warning here
        end
      end

      #utilities
      def debug(msg, level=0)
        if (DEBUG_LEVEL > level)
          puts msg
        end
      end

      def publish(msg)
        debug "About to publish message #{msg}"
        @exchange.publish(msg)
      end

      def add_to_users(info)
        @lock.synchronize { 
          if (info[:name])
            info = info.stringify_keys
          end
          name = info['name'];
          if (name)
            debug "Adding info to users: #{info}"
            self.users[info['name']] = { start_time: info['start_time'], is_leader: info['is_leader'], last_modified: Time.now.to_i }
          else
            puts "WARNING! no info['name'] in add_to_users"
          end
        }
      end

      def remove_from_users(name)
        self.users.delete(name)
      end

      def current_leader
        current_leader = nil
        users.each_pair do |k,v|
          if (v[:is_leader])
            current_leader = k
            break
          end
        end
        current_leader
      end

      def display_current_leader
        if (current_leader)
          puts "Current_leader_is #{current_leader}"
        else
          puts "WARNING! There is no current leader!"
        end
      end

      def is_same_user?(other_user)
        user_name == other_user
      end

      def sent_by_leader?(info)
        user = users[info['name']]
        user && user[:is_leader]
      end

      #messages
      def request_roll_call
        msg = { name: user_name, type: "directive", message: 'roll_call', is_leader: is_leader }.to_json
        debug "ANNOUNCE ROLL CALL: About to publish msg: #{msg}", 1
        publish(msg)
      end

      def announce_self(first_time=false)
        msg = { name: user_name, type: "announce", start_time: start_time, is_leader: is_leader, state: state, first_time: first_time }.to_json
        debug "ANNOUNCE: About to publish msg: #{msg}", 1
        publish(msg) 
      end

      def announce_election
        msg = { name: user_name, type: "election", message: "announce", election_start_time: Time.now.to_i }.to_json

        publish(msg)
      end

      def announce_alive
        msg = { name: user_name, type: "election", message: "alive", start_time: start_time, is_leader: is_leader, state: state }.to_json
        publish(msg)
      end

      def announce_victory
        msg = { name: user_name, type: "election", message: "victory"}.to_json
        publish(msg)
      end

      #hChoose new leader
      def do_election(election_start_time)
        announce_alive

        sleep(CONNECT_WAIT_TIME)

        latest_users = users.select { |k,v| v[:last_modified] >= election_start_time }

        #find the user with the oldest start_time starting with current start_time
        best_start_time = start_time
        selected_leader = user_name
       
        latest_users.each_pair do |k,v| 
          if (v[:start_time] < best_start_time)
            best_start_time = v[:start_time]
            selected_leader = k
          end
        end

        debug "selected leader = #{selected_leader}"

        if (selected_leader == user_name)
          self.is_leader = true
          announce_victory
          puts "[!] Your are now the chat leader!"
        end
      end

      def leave_chat
        if (state == STATE_CONNECTED)
          msg = { name: user_name, type: "leave" }.to_json
          publish(msg)
        end
        #if current users is the leader, then start the choose new leader process 
        if (is_leader)
          announce_election
        end
      end

      def exit_program
        debug "IN EXIT PROGRAM!"
        leave_chat
        self.state=STATE_DONE
        #bunny_bridge_chat.close
        channel.close
        bunny_connection.close
      end

  end #Node
end #DistrubutedChat

