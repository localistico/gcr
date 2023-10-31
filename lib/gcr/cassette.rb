class GCR::Cassette
  VERSION = 2

  attr_reader :reqs, :before_record_request, :path, :dedupe_requests, :start_playback_from

  # Delete all recorded cassettes.
  #
  # Returns nothing.
  def self.delete_all
    Dir[File.join(GCR.cassette_dir, "*.json")].each do |path|
      File.unlink(path)
    end
  end

  # Initialize a new cassette.
  #
  # name - The String name of the recording, from which the path is derived.
  #
  # Returns nothing.
  def initialize(name, before_record_request: nil, dedupe_requests: true)
    @path = File.join(GCR.cassette_dir, "#{name}.json")
    @reqs = []
    FileUtils.mkdir_p(File.dirname(@path))
    @before_record_request = before_record_request || -> (req) { nil }
    @dedupe_requests = dedupe_requests
    @start_playback_from = 0
  end

  # Does this cassette exist?
  #
  # Returns boolean.
  def exist?
    File.exist?(@path)
  end

  def dedupe_requests?
    @dedupe_requests
  end

  # Load this cassette.
  #
  # Returns nothing.
  def load
    data = JSON.parse(File.read(@path))

    if data["version"] != VERSION
      raise "GCR cassette version #{data["version"]} not supported"
    end

    @reqs = data["reqs"].map do |req, resp|
      [GCR::Request.from_hash(req), GCR::Response.from_hash(resp)]
    end

    if dedupe_requests?
      @reqs.each_with_index do |req_resp, i|
        if @reqs[i+1..].any? { |other_req_resp| other_req_resp[0] == req_resp[0] }
          raise "GCR cassette contains duplicate requests, cannot be replayed with dedupe_requests as true"
        end
      end
    end
  end

  # Persist this cassette.
  #
  # Returns nothing.
  def save
    return if reqs.empty? && !GCR.save_empty_requests?

    File.open(@path, "w") do |f|
      f.write(JSON.pretty_generate(
        "version" => VERSION,
        "reqs" => reqs,
      ))
    end
  end

  # Record all GRPC calls made while calling the provided block.
  #
  # Returns nothing.
  def record(&blk)
    start_recording
    blk.call
  ensure
    stop_recording
  end

  # Play recorded GRPC responses.
  #
  # Returns nothing.
  def play(&blk)
    start_playing
    blk.call
  ensure
    stop_playing
  end

  def start_recording
    GCR.stubs.each { |stub| start_recording_for_stub(stub) }
  end

  def start_recording_for_stub(stub)
    stub.class.class_eval do
      alias_method :orig_request_response, :request_response

      def request_response(*args, return_op: false, **kwargs)
        if return_op
          # capture the operation
          operation = orig_request_response(*args, return_op: return_op, **kwargs)
          original_execute = operation.method(:execute)
          operation.define_singleton_method(:execute) do
            original_execute.call.tap do |resp|
              req = GCR::Request.from_proto(*args)
              resp = GCR::Response.from_proto(resp)
              GCR.cassette.before_record_request.call(req)
              if !GCR.cassette.dedupe_requests? || GCR.cassette.reqs.none? { |r, _| r == req }
                GCR.cassette.reqs << [req, resp]
              end
            end
          end

          # then return it
          operation
        else
          orig_request_response(*args, return_op: return_op, **kwargs).tap do |resp|
            req = GCR::Request.from_proto(*args)
            resp = GCR::Response.from_proto(resp)
            GCR.cassette.before_record_request.call(req)
            if !GCR.cassette.dedupe_requests? || GCR.cassette.reqs.none? { |r, _| r == req }
              GCR.cassette.reqs << [req, resp]
            end
          end
        end
      end
    end
  end

  def stop_recording
    GCR.stubs.each { |stub| stop_recording_for_stub(stub) }
    save
  end

  def stop_recording_for_stub(stub)
    stub.class.class_eval do
      alias_method :request_response, :orig_request_response
    end
  end

  def get_response!(req)
    before_record_request.call(req)  # To make sure the request matches the recorded ones

    reqs[start_playback_from..].each.with_index(start_playback_from + 1) do |req_resp, next_start_from|
      recorded_req, recorded_resp = req_resp
      if req == recorded_req
        if !dedupe_requests?
          # If there can be duplicate requests, need to keep track of the
          # position in the cassette, so that subsequent requests are
          # replayed with their subsequent responses, otherwise the first
          # request will be played back all the time.
          @start_playback_from = next_start_from
        end

        return recorded_resp
      end
    end
    position_msg = start_playback_from > 0 ? "after position #{start_playback_from} " : ""

    msg = <<~errmsg.strip
    No request found #{position_msg} matching

    #{pretty_print_request(req)}

    Requests recorded in cassette #{path}:

    errmsg

    reqs.each_with_index do |req_resp, i|
      if start_playback_from > 0 and start_playback_from == i
        msg << "\n\n** playing back from here"
      end
      msg << "\n\n- #{pretty_print_request(req_resp[0], indent='  ')}"
    end
    raise GCR::NoRecording.new(msg + "\n\n")
  end

  def start_playing
    @start_playback_from = 0
    load

    GCR.stubs.each { |stub| start_playing_for_stub(stub) }
  end

  def start_playing_for_stub(stub)
    stub.class.class_eval do
      alias_method :orig_request_response, :request_response

      def request_response(*args, return_op: false, **kwargs)
        req = GCR::Request.from_proto(*args)
        resp = GCR.cassette.get_response!(req)

        # check if our request wants an operation returned rather than the response
        if return_op
          # if so, collect the original operation
          operation = orig_request_response(*args, return_op: return_op, **kwargs)

          # hack the execute method to return the response we recorded
          operation.define_singleton_method(:execute) { return resp.to_proto }

          # then return it
          return operation
        else
          # otherwise just return the response
          return resp.to_proto
        end
      end
    end
  end

  def pretty_print_request(req, indent='')
    (
      "#{req.class_name}\n" +
      "#{indent}  route=#{req.route}\n" +
      "#{indent}  body=#{req.body}"
    )
  end

  def stop_playing
    GCR.stubs.each { |stub| stop_playing_for_stub(stub) }
  end

  def stop_playing_for_stub(stub)
    stub.class.class_eval do
      alias_method :request_response, :orig_request_response
    end
  end

  def [](req)
    reqs.find { |r| r == req }
  end

  def []=(req, resp)
    reqs << [req, resp]
  end
end
