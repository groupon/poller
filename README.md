Poller - poll a URL, and trigger code on changes
================================================

**Poller** is a Ruby gem and a command line utility to poll a URL for
changes; that is, to repeatedly fetch that URL, and trigger some
code whenever the content returned by fetching the URL changes.

The gem API takes a URL, some options, and a Ruby code block. It loads
the contents of that URL, and runs the code block whenever those
contents change. The code block gets passed a filehandle opened for
reading, whose contents are the response body from fetching that URL.

The command line tool is similar, but takes a command to run instead of
a Ruby code block; the command gets as an argument the filename of a
tempfile that has the contents from fetching that URL.

Some example use cases are synchronizing a local configuration file with
a master copy exposed from a centralized configuration management
system, or monitoring a URL and e-mailing diffs to yourself when that
URL changes.

Getting Started
---------------

Install it:

    $ gem install poller

Reference it in your [Bundler](http://gembundler.com/) Gemfile:

    gem 'poller'

Use it in Ruby code:

    require 'rubygems'
    require 'poller'
    
    Poller.new('http://example.com/foo.json').run do |fh|
      json = fh.read
      # Do something with json...
    end

Use it from the command line:

    $ poller http://example.com/foo.json /path/to/process_json

License
-------

    Copyright (c) 2012, Groupon, Inc.
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:
    
    Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
    
    Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
    
    Neither the name of GROUPON nor the names of its contributors may be
    used to endorse or promote products derived from this software without
    specific prior written permission.
    
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
    IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
    TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
    PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
    TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
    PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
    LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
    NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Meta
----

* Home: <https://github.com/groupon/poller>
* Bugs: <https://github.com/groupon/poller/issues>
* Authors: <https://github.com/andrewgho>
