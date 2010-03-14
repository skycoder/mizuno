require 'java'
require 'ruby_input_stream'

# We assume that Servlets and Continuations have been loaded by the
# Jetty handler.

include_class javax.servlet.http.HttpServlet

#
# Wraps a Rack application in a Java servlet.
#
# FIXME: relativeResourceBase?
#
# http://rack.rubyforge.org/doc/SPEC.html
# http://java.sun.com/j2ee/sdk_1.3/techdocs/api/javax/servlet/http/HttpServlet.html
#
class RackServlet < HttpServlet
    include_class java.io.FileInputStream
    include_class org.eclipse.jetty.continuation.ContinuationSupport

    #
    # Sets the Rack application that handles requests sent to this
    # servlet container.
    #
    def rackup(app)
        @app = app
    end

    #
    # Takes an incoming request (as a Java Servlet) and dispatches it to
    # the rack application setup via [rackup].  All this really involves
    # is translating the various bits of the Servlet API into the Rack
    # API on the way in, and translating the response back on the way
    # out.
    #
    def service(request, response)
        # Turn the ServletRequest into a Rack env hash
        env = servlet_to_rack(request)

	# Handle asynchronous responses via Servlet continuations.
	continuation = ContinuationSupport.getContinuation(request)

	# We should never be re-dispatched.
	raise("Request re-dispatched.") unless continuation.isInitial

	# Add our own special bits to the rack environment so that 
	# Rack middleware can have access to the Java internals.
	env['rack.java.servlet'] = true
	env['rack.java.servlet.request'] = request
	env['rack.java.servlet.response'] = response
	env['rack.java.servlet.continuation'] = continuation

	# Add an callback that can be used to add results to the
	# response asynchronously.
	env['async.callback'] = lambda do |rack_response|
	    servlet_response = continuation.getServletResponse
	    finished = rack_to_servlet(rack_response, servlet_response)
	    continuation.complete if finished
	end

	# Execute the Rack request.
	catch(:async) do
	    rack_response = @app.call(env)
	   
	    # For apps that don't throw :async.
	    unless(rack_response[0] == -1)
		# Nope, nothing asynchronous here.
		rack_to_servlet(rack_response, response)
		return
	    end
	end

	# If we got here, this is a continuation.
	continuation.suspend(response)
    end

    private

    #
    # Turns a Servlet request into a Rack request hash.
    #
    def servlet_to_rack(request)
        # The Rack request that we will pass on.
        env = Hash.new

	# Map Servlet bits to Rack bits.
	env['REQUEST_METHOD'] = request.getMethod
	env['QUERY_STRING'] = request.getQueryString.to_s
	env['SERVER_NAME'] = request.getServerName
	env['SERVER_PORT'] = request.getServerPort.to_s
	env['rack.version'] = Rack::VERSION
	env['rack.url_scheme'] = request.getScheme
	env['HTTP_VERSION'] = request.getProtocol
	env['REMOTE_ADDR'] = request.getRemoteAddr
	env['REMOTE_HOST'] = request.getRemoteHost

	# FIXME: Not sure what this should be...
	env['SCRIPT_NAME'] = ''

	# request.getPathInfo seems to be blank, so we're using the URI.
	env['PATH_INFO'] = request.getRequestURI

	# Rack says URI, but it hands off a URL.
	env['REQUEST_URI'] = request.getRequestURL.toString

	# Java chops off the query string, but a Rack application will
	# expect it, so we'll add it back if present
	env['REQUEST_URI'] << "?#{env['QUERY_STRING']}" \
	    if env['QUERY_STRING']

	# FIXME
	# It's a given that we're single-process on JRuby, because we
	# can't fork, but this should probably be user-settable.
	env['rack.multiprocess'] = false
	env['rack.multithread'] = true
	env['rack.run_once'] = false

	# Populate the HTTP headers.
	request.getHeaderNames.each do |header_name|
	    header = header_name.upcase.tr('-', '_')
	    env["HTTP_#{header}"] = request.getHeader(header_name)
	end

	# Rack Weirdness: HTTP_CONTENT_TYPE and HTTP_CONTENT_LENGTH
	# both need to have the HTTP_ part dropped.
	env["CONTENT_TYPE"] = env.delete("HTTP_CONTENT_TYPE") \
	    if env["HTTP_CONTENT_TYPE"]
	env["CONTENT_LENGTH"] = env.delete("HTTP_CONTENT_LENGTH") \
	    if env["HTTP_CONTENT_LENGTH"]

	# The input stream is a wrapper around the Java InputStream.
	env['rack.input'] = RubyInputStream.new(request.getInputStream)

	# The output stream defaults to stderr.
	env['rack.errors'] ||= $stderr

	# All done, hand back the Rack request.
	return(env)
    end

    #
    # Turns a Rack response into a Servlet response; can be called
    # multiple times.  Returns true if this is the full request (either
    # a synchronous request or the last part of an async request),
    # false otherwise.
    #
    def rack_to_servlet(rack_response, response)
        # Split apart the Rack response.
        status, headers, body = rack_response

	# Set the HTTP status code.
	response.setStatus(status)

	# Add all the result headers.
	# FIXME/TEST: Multiple Set-Cookie?
	headers.each_pair { |h, v| response.addHeader(h, v) }

	# How else would we write output?
	output = response.getOutputStream

	# Handle the result body.
	if(body.respond_to?(:to_path))
	    # We've been told to serve a file; use FileInputStream to
	    # stream the file directly to the servlet, because this
	    # is a lot faster than doing it with Ruby.
	    #
	    # FIXME: Make the buffer size adjustable, or detect the
	    # filesystem's ideal block size a-la cp.
	    buffer = Java::byte[1024].new
	    file = FileInputStream.new(body.to_path)
	    while((count = file.read(buffer)) != -1)
	        output.write(buffer, 0, count)
	    end
	    file.close
	else
	    # Nope, we've got something that responds to each; send
	    # that to the servlet PrintWriter.
	    body.each { |l| output.print(l) }
	end

	# Close the body if we're supposed to.
	body.close if body.respond_to?(:close)

	# All done.
	output.flush

	# Is this an synchonous call?
	return(true) unless body.respond_to?(:finished?)
	return(body.finished? == true)
    end
end
