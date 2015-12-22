#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2013, 2014, 2015 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, and
# distribution of modified versions of this work as long as this
# notice is included.
#++
require_relative "util"
require_relative "server"
require_relative "note"

require 'set'

module SonicPi
  class Studio
    include Util

    attr_reader :synth_group, :fx_group, :mixer_group, :recording_group, :mixer_id, :mixer_bus, :mixer, :max_concurrent_synths, :rand_buf_id, :amp

    def initialize(hostname, port, msg_queue, max_concurrent_synths)
      @hostnane = hostname
      @port = port
      @msg_queue = msg_queue
      @max_concurrent_synths = max_concurrent_synths
      @error_occured_mutex = Mutex.new
      @error_occurred_since_last_check = false
      @sample_sem = Mutex.new
      @server_mutex = Mutex.new
      init_studio
      reset_server
    end

    def init_studio
      message "Initializing..."
      @amp = [0.0, 1.0]

      server = Server.new(@hostname, @port, @msg_queue)
      server.load_synthdefs(synthdef_path)
      server.add_event_handler("/sonic-pi/amp", "/sonic-pi/amp") do |payload|
        @amp = [payload[2], payload[3]]
      end
      # load rand stream directly - ensuring it doesn't get considered as a 'sample'
      rand_buf_id = server.buffer_alloc_read(buffers_path + "/rand-stream.wav").to_i
      old_samples = @samples
      @samples = {}

      (old_samples || {}).each do |k, v|
        message "Reloading sample - #{unify_tilde_dir(k)}"
        load_sample(k, server)
      end

      old_synthdefs = @loaded_synthdefs
      @loaded_synthdefs = Set.new

      (old_synthdefs || []).each do |s|
        message "Reloading synthdefs in #{unify_tilde_dir(s)}"
        load_synthdefs(s, server)
      end

      @recorders = {}
      @recording_mutex = Mutex.new
      @server = server

      @rand_buf_id = rand_buf_id
      @check_server_t = Thread.new do
        loop do
          @server_mutex.synchronize do
            begin
              if server.status(5)
                # server is alive
              else
                @error_occured_mutex.synchronize do
                  @error_occurred_since_last_check = true
                end
                message "Sound server is down."
                reboot
                Thread.current.kill
              end
            rescue
              @error_occured_mutex.synchronize do
                @error_occurred_since_last_check = true
              end
              message "Error communicating with sound server."
              reboot
              Thread.current.kill
            end
          end
          Kernel.sleep 5
        end
      end
    end

    def error_occurred?
      @error_occured_mutex.synchronize do
        if @error_occurred_since_last_check
          @error_occurred_since_last_check = false
          return true
        else
          return false
        end
      end
    end

    def load_synthdefs(path, server=@server)
      @sample_sem.synchronize do
        server.load_synthdefs(path)
        @loaded_synthdefs << path
      end
    end

    def sample_loaded?(path)
      return @samples.has_key?(path)
    end

    def load_sample(path, server=@server)
      return [@samples[path], true] if @samples[path]
      #message "Loading full sample path: #{path}"
      buf_info = nil
      @sample_sem.synchronize do
        return @samples[path] if @samples[path]
        buf_info = server.buffer_alloc_read(path)
        buf_info.path = path
        @samples[path] = buf_info
      end
      [buf_info, false]
    end

    def free_sample(paths, server=@server)
      @sample_sem.synchronize do
        paths.each do |p|
          info = @samples[p]
          @samples.delete(p)
          server.buffer_free(info) if info
        end
      end
      :free
    end

    def free_all_samples(server=@server)
      @sample_sem.synchronize do
        @samples.each do |k, v|
          server.buffer_free(v)
        end
        @samples = {}
      end
    end

    def reset_and_setup_groups_and_busses
      @server.clear_scsynth!
      @mixer_bus = @server.allocate_audio_bus
      @mixer_group = @server.create_group(:head, 0, "STUDIO-MIXER")
      @fx_group = @server.create_group(:before, @mixer_group, "STUDIO-FX")
      @synth_group = @server.create_group(:before, @fx_group, "STUDIO-SYNTHS")
      @recording_group = @server.create_group(:after, @mixer_group, "STUDIO-RECORDING")
    end

    def reset_server
      reset_and_setup_groups_and_busses
      start_mixer
    end

    def start_amp_monitor
      unless @amp_synth
        @amp_synth = @server.trigger_synth :head, @recording_group, "sonic-pi-amp_stereo_monitor", {"bus" => 0}, true
      end
    end


    def message(s)
      @msg_queue.push({:type => :info, :val => "Studio: #{s.to_s}"})
    end

    def trigger_synth(synth_name, group, args, info, now=false, t_minus_delta=false )
      @server.trigger_synth(:head, group, synth_name, args, info, now, t_minus_delta)
    end

    def start_mixer
      #message "Starting mixer"
      # TODO create a way of swapping these on the fly:
      # set_mixer! :basic
      # set_mixer! :default
      mixer_synth = raspberry_pi_1? ? "sonic-pi-basic_mixer" : "sonic-pi-mixer"
      @mixer = @server.trigger_synth(:head, @mixer_group, mixer_synth, {"in_bus" => @mixer_bus.to_i}, nil, true)
    end

    def volume=(vol)
      message "Setting main volume to #{vol}"
      @server.node_ctl @mixer, {"amp" => vol}
    end

    def mixer_invert_stereo(invert)
      # invert should be true or false
      invert_i = invert ? 1 : 0
      @server.node_ctl @mixer, {"invert_stereo" => invert_i}, true
    end

    def mixer_control(opts)
      now = 0
      opts = opts.clone
      if opts[:now].is_a?(Numeric)
        now = opts[:now]
      else
        now = opts[:now] ? 1 : 0
      end
      opts.delete :now
      @server.node_ctl @mixer, opts, now
    end

    def mixer_reset
      info = Synths::SynthInfo.get_info(:main_mixer)
      mixer_control(info.slide_arg_defaults)
      mixer_control(info.arg_defaults)
    end

    def mixer_stereo_mode
      @server.node_ctl @mixer, {"force_mono" => 0}, true
    end

    def mixer_mono_mode
      @server.node_ctl @mixer, {"force_mono" => 1}, true
    end

    def status
      @server.status
    end

    def stop
      @server.clear_schedule
      @server.group_clear @synth_group
    end

    def new_group(position, target, name="")
      @server.create_group(position, target, name)
    end

    def new_synth_group(id=-1)
      new_group(:tail, @synth_group, "Run-#{id}-Synths")
    end

    def new_fx_group(id=-1)
      new_group(:tail, @fx_group, "Run-#{id}-FX")
    end

    def new_fx_bus
      @server.allocate_audio_bus
    end

    def sched_ahead_time
      @server.sched_ahead_time
    end

    def sched_ahead_time=(t)
      @server.sched_ahead_time = t
    end

    def control_delta
      @server.control_delta
    end

    def control_delta=(t)
      @server.control_delta = t
    end

    def recording?(bus=0)
      @recorders[bus]
    end

    def recording_start(path, bus=0)
      return false if @recorders[bus]
      @recording_mutex.synchronize do
        return false if @recorders[bus]
        bs = @server.buffer_stream_open(path)
        s = @server.trigger_synth :head, @recording_group, "sonic-pi-recorder", {"out-buf" => bs.to_i, "in_bus" => bus.to_i}, true
        @recorders[bus] = [bs, s]
        true
      end
    end

    def recording_stop(bus=0)
      return false unless @recorders[bus]
      @recording_mutex.synchronize do
        return false unless @recorders[bus]
        bs, s = @recorders[bus]
        bs.free
        s.kill
        @recorders.delete bus
        true
      end
    end

    def shutdown
      @server.shutdown
    end

    def reboot
      @server_mutex.synchronize do
        message "Rebooting server..."
        shutdown
        init_studio
        reset_server
        message "Server ready."
      end
    end
  end
end
