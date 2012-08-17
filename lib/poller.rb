# = Poller - poll a URL, and trigger code on changes
#
# For more details, please visit the
# {Poller GitHub page}[https://github.com/groupon/poller/"target="_parent].
#
# == License
#
#   Copyright (c) 2012, Groupon, Inc.
#   All rights reserved.
#   
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions
#   are met:
#   
#   Redistributions of source code must retain the above copyright notice,
#   this list of conditions and the following disclaimer.
#   
#   Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
#   
#   Neither the name of GROUPON nor the names of its contributors may be
#   used to endorse or promote products derived from this software without
#   specific prior written permission.
#   
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
#   IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
#   TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
#   PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#   HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
#   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
#   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
#   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
#   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'pathname'
require 'uri'
require 'net/http'
require 'tmpdir'
require 'time'
require 'fileutils'
require 'logger'
require 'digest/md5'

# = Poller - poll a URL, and trigger code on changes
#
# Poller is a gem and a command line utility to poll a URL for
# changes; that is, to repeatedly fetch that URL, and trigger some
# code whenever the content returned by fetching the URL changes.
#
# For more details, please visit the
# {Poller GitHub page}[https://github.com/groupon/poller/"target="_parent].

class Poller

  # When you invoke Poller, you pass the initializer a URL to fetch, and
  # a hash of options. The following options are recognized:
  #
  # [<tt>:interval</tt>]      wait this many seconds between fetches (default 1)
  # [<tt>:timeout</tt>]       fail fetch after this many seconds (default 15)
  # [<tt>:backoff</tt>]       poll interval after error responses (default 30)
  # [<tt>:cache_dir</tt>]     store cached file in this dir (default tempdir)
  # [<tt>:master_file</tt>]   filename of cached master file (default tempdir)
  # [<tt>:mtime_updates</tt>] run if mtime changed, but not content (default no)
  # [<tt>:proxy_host</tt>]    HTTP proxy host (default nil, meaning no proxy)
  # [<tt>:proxy_port</tt>]    HTTP proxy port
  # [<tt>:logger</tt>]        Logger object (default is no logging)
  #
  # The +interval+, +timeout+, and +backoff+ options control how
  # aggressively Poller will fetch the URL.
  #
  # The +cache_dir+ and +master_file+ options control where Poller
  # stores its cached copy of the response body; by default, Poller
  # creates a new temporary directory. Setting +cache_dir+ lets you
  # choose a temporary directory of your own; setting +master_file+ lets
  # you put the file somewhere that external programs can access it
  # (Poller does atomic file updates, so, it is safe to use it to update
  # things like server configuration files).
  #
  # Poller uses HTTP/1.1 conditional requests (with an If-Modified-Since
  # header) to try to minimize the number of times it fetches the URL.
  # By default, Poller will only run the code block if the actual
  # response body changes, not if just the Last-Modified date changes.
  # Setting +mtime_updates+ to true will change that to run whenever
  # a response status that is not 304 Not Modified is returned.

  def initialize(uri, opts = {})

    @uri           = URI.parse(uri)
    @interval      = opts[:interval]      || 1
    @timeout       = opts[:timeout]       || 15
    @backoff       = opts[:backoff]       || 30
    @cache_dir     = opts[:cache_dir]     || nil
    @master_file   = opts[:master_file]   || nil
    @mtime_updates = opts[:mtime_updates] || false
    @proxy_host    = opts[:proxy_host]    || nil
    @proxy_port    = opts[:proxy_port]    || 3128
    @logger        = opts[:logger]        || NullLogger.new

    logger.debug "initialize(#{uri.inspect}, #{opts.inspect})"

    # If using HTTP proxy, set that class up now
    if @proxy_host
      logger.debug "using HTTP proxy #{@proxy_host}:#{@proxy_port}"
      @http_class = Net::HTTP::Proxy(@proxy_host, @proxy_port)
    else
      @http_class = Net::HTTP
    end

    # If cache file was specified and absolute, make sure directory matches
    if @master_file
      if Pathname.new(@master_file).absolute?
        if @cache_dir && @cache_dir != File.dirname(@master_file)
          raise "@master_file must be in #{@cache_dir}: #{@master_file}"
        elsif !@cache_dir
          @cache_dir = File.dirname(@master_file)
        end
      elsif @master_file != File.basename(@master_file)
        raise "master_file must be absolute, or bare filename: #{@master_file}"
      end
    end
  end

  # <tt>Poller#run()</tt> starts a polling loop. It takes a code block
  # to run, whenever the URL's contents change. The code block gets
  # passed a filehandle, opened for reading, whose contents are the
  # response body from fetching the URL.
  #
  # The return value of the block should be a boolean, indicating
  # whether Poller should continue doing its work, or exit.

  def run
    # This code protected by ensure block that deletes any temporary directory
    candidate_file = nil
    remove_dir = false
    begin

      # Verify cache directory exists, or, create temporary directory for it
      if @cache_dir
        unless File.directory?(@cache_dir)
          raise "cache directory does not exist: #{@cache_dir}"
        end
      else
        @cache_dir = Dir.mktmpdir
        logger.debug "created cache_dir = #{@cache_dir.inspect}"
        remove_dir = true
      end
      @master_file ||= File.join(@cache_dir, 'master')

      # If cache file was specified and non-absolute, make it absolute now
      unless Pathname.new(@master_file).absolute?
        @master_file = File.join(@cache_dir, @master_file)
      end

      # We keep master (cached) and candidate (possible replacement) files
      candidate_file = File.join(@cache_dir, "candidate.#$$")
      logger.debug "master_file = #{@master_file.inspect}; " +
                   "candidate_file = #{candidate_file.inspect}"

      # Always run once; caller passes block that determines if we keep running
      should_continue = true
      while should_continue
        sleep_interval = @interval

        # Record MD5 checksum and modification time on master file
        master_md5sum = md5sum(@master_file)
        master_mtime = mtime(@master_file)
        logger.debug "master_md5sum = #{master_md5sum.inspect}; " +
                     "master_mtime = #{master_mtime.inspect}"

        # Fetch new candidate file
        logger.debug "fetching uri = #{@uri.to_s.inspect}"
        request = @http_class::Get.new(@uri.request_uri)
        if master_mtime
          if_modified_since = master_mtime.rfc822
          logger.debug "If-Modified-Since: #{if_modified_since}"
          request.add_field('If-Modified-Since', if_modified_since)
        end
        begin
          @http_class.start(@uri.host, @uri.port) do |http|
            http.request(request) do |response|
              logger.debug "response.code = #{response.code.inspect}"
              if response.is_a?(Net::HTTPNotModified)
                logger.debug 'master file up to date'
              elsif response.is_a?(Net::HTTPSuccess)

                # Write and set mtime on new candidate file, and get MD5 checksum
                logger.debug "writing candidate_file = #{candidate_file.inspect}"
                md5 = Digest::MD5.new
                File.open(candidate_file, 'w') do |io|
                  response.read_body do |chunk|
                    logger.debug "chunk.size = #{chunk.size}"
                    md5.update(chunk)
                    io.write(chunk)
                  end
                end
                candidate_md5sum = md5.hexdigest
                if (last_modified = response['Last-Modified'])
                  logger.debug "Last-Modified: #{last_modified}"
                  candidate_mtime = Time.parse(last_modified)
                  File.utime(candidate_mtime, candidate_mtime, candidate_file)
                else
                  candidate_mtime = nil
                end
                logger.debug "candidate_md5sum = #{candidate_md5sum.inspect}; " +
                             "candidate_mtime = #{candidate_mtime.inspect}"

                # If candidate does not exactly match master, replace master
                mtime_changed =
                  master_mtime.nil? || candidate_mtime != master_mtime
                md5sum_changed =
                  master_md5sum.nil? || candidate_md5sum != master_md5sum
                if mtime_changed || md5sum_changed
                  File.rename(candidate_file, @master_file)
                  change_type =
                    md5sum_changed ? 'fetched new content' : 'updated mtime'
                  logger.info "#{change_type} from URI: #{@uri}"
                  if md5sum_changed || @mtime_updates
                    # Content changed, or caller opted for mtime updates
                    should_continue = File.open(@master_file) { |fh| yield fh }
                  else
                    should_continue = true
                  end
                else
                  logger.debug 'skipping update since candidate matches master'
                end

              else
                status_line = "#{response.code} #{response.message}"
                logger.error "error fetching #{@uri}: HTTP status #{status_line}"
                sleep_interval = @backoff
              end
            end
          end
        rescue Exception => e
          logger.error "error fetching #{@uri}: #{e}"
          sleep_interval = @backoff
        end

        # Sleep for a short interval to avoid stressing the upstream server
        if should_continue
          logger.debug "sleep_interval = #{sleep_interval}"
          sleep(sleep_interval)
        end

      end

    # Always make sure tempfile and cache directory are cleaned up
    ensure
      if candidate_file && File.exists?(candidate_file)
        logger.debug "removing candidate file: #{candidate_file}"
        FileUtils.remove_entry_secure(candidate_file)
      end
      if remove_dir
        logger.debug "removing cache directory: #{@cache_dir}"
        FileUtils.remove_entry_secure(@cache_dir) if File.directory?(@cache_dir)
      end
    end

  end

  private

  # Return the configured logger, or, a new NullLogger if there is none
  def logger
    @logger ||= NullLogger.new
    @logger
  end

  # A NullLogger is a stubbed-out Logger which does nothing
  class NullLogger < Logger  # :nodoc:
    def initialize(*args); end
    def add(*args); end
    def <<(*args); end
    def inspect; "#<Poller::NullLogger level=#{level}>"; end
  end

  # Run block, but demote "file does not exist" exceptions to returning nil
  def file_try
    begin
      retval = yield
    rescue Errno::ENOENT
      retval = nil
    end
    retval
  end

  # Return MD5 hex digest for a file, nil if the file does not exist
  def md5sum(filename)
    file_try { Digest::MD5.file(filename).hexdigest }
  end

  # Return last modification time of file, nil if the file does not exist
  def mtime(filename)
    file_try { File.mtime(filename) }
  end
end
