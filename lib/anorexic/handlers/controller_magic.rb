module Anorexic

	# the methods defined in this module will be injected into the Controller class passed to
	# Anorexic (using the `route` or `shared_route` commands), and will be available
	# for the controller to use within it's methods.
	#
	# for some reason, the documentation ignores the following additional attributes, which are listed here:
	#
	# request:: the HTTPRequest object containing all the data from the HTTP request. If a WebSocket connection was established, the `request` object will continue to contain the HTTP request establishing the connection (cookies, parameters sent and other information).
	# params:: any parameters sent with the request (short-cut for `request.params`), will contain any GET or POST form data sent (including file upload and JSON format support).
	# cookies:: a cookie-jar to get and set cookies (set: `cookie\[:name] = data` or get: `cookie\[:name]`). Cookies and some other data must be set BEFORE the response's headers are sent.
	# flash:: a temporary cookie-jar, good for one request. this is a short-cut for the `response.flash` which handles this magical cookie style.
	# response:: the HTTPResponse **OR** the WSResponse object that formats the response and sends it. use `response << data`. This object can be used to send partial data (such as headers, or partial html content) in blocking mode as well as sending data in the default non-blocking mode.
	# host_params:: a copy of the parameters used to create the host and service which accepted the request and created this instance of the controller class.
	#
	module ControllerMagic
		def self.included base
			base.send :include, InstanceMethods
			base.extend ClassMethods
		end

		module InstanceMethods
			module_function
			public

			# the request object, class: HTTPRequest.
			attr_reader :request

			# the ::params variable contains all the paramaters set by the request (/path?locale=he  => params["locale"] == "he").
			attr_reader :params

			# a cookie-jar to get and set cookies (set: `cookie\[:name] = data` or get: `cookie\[:name]`).
			#
			# Cookies and some other data must be set BEFORE the response's headers are sent.
			attr_reader :cookies

			# the HTTPResponse **OR** the WSResponse object that formats the response and sends it. use `response << data`. This object can be used to send partial data (such as headers, or partial html content) in blocking mode as well as sending data in the default non-blocking mode.
			attr_accessor :response

			# the ::flash is a little bit of a magic hash that sets and reads temporary cookies.
			# these cookies will live for one successful request to a Controller and will then be removed.
			attr_reader :flash

			# the parameters used to create the host (the parameters passed to the `listen` / `add_service` call).
			attr_reader :host_params

			# checks whether this instance accepts broadcasts (WebSocket instances).
			def accepts_broadcast?
				@_accepts_broadcast
			end

			# this method does two things.
			#
			# 1. sets redirection headers for the response.
			# 2. sets the `flash` object (short-time cookies) with all the values passed except the :status value.
			#
			# use:
			#      redirect_to 'http://google.com', notice: "foo", status: 302
			#      # => redirects to 'http://google.com' with status 302 and adds notice: "foo" to the flash
			# or simply:
			#      redirect_to 'http://google.com'
			#      # => redirects to 'http://google.com' with status 302 (default status)
			#
			# if the url is a symbol, the method will try to format it into a correct url, replacing any
			# underscores ('_') with a backslash ('/').
			#
			# if the url is an empty string, the method will try to format it into a correct url
			# representing the index of the application (http://server/)
			#
			def redirect_to url, options = {}
				return super *[] if defined? super
				raise 'Cannot redirect after headers were sent' if response.headers_sent?
				url = "#{request.base_url}/#{url.to_s.gsub('_', '/')}" if url.is_a?(Symbol) || ( url.is_a?(String) && url.empty? ) || url.nil?
				# redirect
				response.status = options.delete(:status) || 302
				response['Location'] = url
				response['content-length'] ||= 0
				flash.update options
				response.finish
				true
			end

			# this method adds data to be sent.
			#
			# this is usful for sending 'attachments' (data to be downloaded) rather then
			# a regular response.
			#
			# this is also usful for offering a file name for the browser to "save as".
			#
			# it accepts:
			# data:: the data to be sent
			# options:: a hash of any of the options listed furtheron.
			#
			# the :symbol=>value options are:
			# type:: the type of the data to be sent. defaults to empty. if :filename is supplied, an attempt to guess will be made.
			# inline:: sets the data to be sent an an inline object (to be viewed rather then downloaded). defaults to false.
			# filename:: sets a filename for the browser to "save as". defaults to empty.
			#
			def send_data data, options = {}
				raise 'Cannot use "send_data" after headers were sent' if response.headers_sent?
				# write data to response object
				response << data

				# set headers
				content_disposition = "attachment"

				options[:type] ||= MimeTypeHelper::MIME_DICTIONARY[::File.extname(options[:filename])] if options[:filename]

				if options[:type]
					response["content-type"] = options[:type]
					options.delete :type
				end
				if options[:inline]
					content_disposition = "inline"
					options.delete :inline
				end
				if options[:attachment]
					options.delete :attachment
				end
				if options[:filename]
					content_disposition << "; filename=#{options[:filename]}"
					options.delete :filename
				end
				response["content-length"] = data.bytesize rescue true
				response["content-disposition"] = content_disposition
				response.finish
				true
			end

			# renders a template file (.erb/.haml) or an html file (.html) to text
			# for example, to render the file `body.html.haml` with the layout `main_layout.html.haml`:
			#   render :body, layout: :main_layout
			#
			# or, for example, to render the file `json.js.haml`
			#   render :json, type: 'js'
			#
			# or, for example, to render the file `template.haml`
			#   render :template, type: ''
			#
			# template:: a Symbol for the template to be used.
			# options:: a Hash for any options such as `:layout` or `locale`.
			# block:: an optional block, in case the template has `yield`, the block will be passed on to the template and it's value will be used inplace of the yield statement.
			#
			# options aceept the following keys:
			# type:: the types for the `:layout' and 'template'. can be any extention, such as `"json"`. defaults to `"html"`.
			# layout:: a layout template that has at least one `yield` statement where the template will be rendered.
			# locale:: the I18n locale for the render. (defaults to params[:locale]) - only if the I18n gem namespace is defined (`require 'i18n'`).
			#
			# if template is a string, it will assume the string is an
			# absolute path to a template file. it will NOT search for the template but might raise exceptions.
			#
			# if the template is a symbol, the '_' caracters will be used to destinguish sub-folders (NOT a partial template).
			#
			# returns false if the template or layout files cannot be found.
			def render template, options = {}, &block
				# make sure templates are enabled
				return false if host_params[:templates].nil?
				# render layout by recursion, if exists
				(return render(options.delete(:layout), options) { render template, options, &block }) if options[:layout]
				# set up defaults
				options[:type] ||= 'html'
				options[:locale] ||= params[:locale].to_sym if params[:locale]
				# options[:locals] ||= {}
				I18n.locale = options[:locale] if defined?(I18n) && options[:locale]
				# find template and create template object
				filename = template.is_a?(String) ? File.join( host_params[:templates].to_s, template) : (File.join( host_params[:templates].to_s, *template.to_s.split('_')) + (options[:type].empty? ? '': ".#{options[:type]}") + '.slim')
				return ( Anorexic.cache_needs_update?(filename) ? Anorexic.cache_data( filename, ( Slim::Template.new() { IO.read filename } ) )  : (Anorexic.get_cached filename) ).render(self, &block) if defined?(::Slim) && Anorexic.file_exists?(filename)
				filename.gsub! /\.slim$/, '.haml'
				return ( Anorexic.cache_needs_update?(filename) ? Anorexic.cache_data( filename, ( Haml::Engine.new( IO.read(filename) ) ) )  : (Anorexic.get_cached filename) ).render(self, &block) if defined?(::Haml) && Anorexic.file_exists?(filename)
				filename.gsub! /\.haml$/, '.erb'
				return ( Anorexic.cache_needs_update?(filename) ? Anorexic.cache_data( filename, ( ERB.new( IO.read(filename) ) ) )  : (Anorexic.get_cached filename) ).result(binding, &block) if defined?(::ERB) && Anorexic.file_exists?(filename)
				return false
			end

			# returns the initial method called (or about to be called) by the router for the HTTP request.
			#
			# this is can be very useful within the before / after filters:
			#   def before
			#     return false unless "check credentials" && [:save, :update, :delete].include?(requested_method)
			#
			# if the controller responds to a WebSockets request (a controller that defines the `on_message` method),
			# the value returned is invalid and will remain 'stuck' on :pre_connect
			# (which is the last method called before the protocol is switched from HTTP to WebSockets).
			def requested_method
				# respond to websocket special case
				return :pre_connect if request['upgrade'] && request['upgrade'].to_s.downcase == 'websocket' &&  request['connection'].to_s.downcase == 'upgrade'
				# respond to save 'new' special case
				return :save if request.request_method.match(/POST|PUT/) && params[:id].nil? || params[:id] == 'new'
				# set DELETE method if simulated
				request.request_method = 'DELETE' if params[:_method].to_s.downcase == 'delete'
				# respond to special :id routing
				return params[:id].to_sym if params[:id] && available_public_methods.include?(params[:id].to_sym)
				#review general cases
				case request.request_method
				when 'GET', 'HEAD'
					return :index unless params[:id]
					return :show
				when 'POST', 'PUT'
					return :update
				when 'DELETE'
					return :delete
				end
				false
			end

			# lists the available methods that will be exposed to HTTP requests
			def available_public_methods
				# set class global to improve performance while checking for supported methods
				@@___available_public_methods___ ||= (((self.class.public_instance_methods - Object.public_instance_methods) - [:before, :after, :save, :show, :update, :delete, :initialize, :on_message, :pre_connect, :on_connect, :on_disconnect] - Anorexic::ControllerMagic::InstanceMethods.instance_methods).delete_if {|m| m.to_s[0] == '_'})
			end

			## WebSockets Magic

			# WebSockets.
			#
			# Use this to brodcast an event to all 'sibling' websockets (websockets that have been created using the same Controller class).
			#
			# accepts:
			# method_name:: a Symbol with the method's name that should respond to the broadcast.
			# *args:: any arguments that should be passed to the method (UNLESS REDIS IS USED).
			# hash:: (REDIS ONLY) any data stored in a key-value hash, that can be converted to string objects.
			#
			# the method will be called asynchrnously for each sibling instance of this Controller class.
			#
			# IF REDIS IS USED, THE METHOD WILL ALSO BE CALLED FOR THE CALLING OBJECT (self).
			# please make sure to write code that will ignore this message if you are using Redis.
			def broadcast method_name, *args, &block
				return false unless self.class.public_instance_methods.include?(method_name)
				self.class.__inner_redis_broadcast(self, method_name, args, block) || self.class.__inner_process_broadcast(self, method_name, args, block)
			end


			# WebSockets.
			#
			# Use this to collect data from all 'sibling' websockets (websockets that have been created using the same Controller class).
			#
			# This method will call the requested method on all instance siblings and return an Array of the returned values (including nil values).
			#
			# This method will block the excecution unless a block is passed to the method - in which case
			#  the block will used as a callback and recieve the Array as a parameter.
			#
			# i.e.
			#
			# this will block: `collect :_get_id`
			#
			# this will not block: `collect(:_get_id) {|a| puts "got #{a.length} responses."; a.each { |id| puts "#{id}"} }
			#
			# accepts:
			# method_name:: a Symbol with the method's name that should respond to the broadcast.
			# *args:: any arguments that should be passed to the method.
			# &block:: an optional block to be used as a callback.
			#
			# the method will be called asynchrnously for each sibling instance of this Controller class.
			def collect method_name, *args, &block
				if block
					Anorexic.push_event((Proc.new() {r = []; ObjectSpace.each_object(self.class) { |controller|  r << controller.method(method_name).call(*args) if controller.accepts_broadcast?  && (controller.object_id != self.object_id)} ; r } ), &block)
					return true
				else
					r = []
					ObjectSpace.each_object(self.class) { |controller|  r << controller.method(method_name).call(*args) if controller.accepts_broadcast?  && (controller.object_id != self.object_id) }
					return r
				end
			end

			# WebSockets.
			#
			# this method handles the protocol and handler transition between the HTTP connection
			# (with a protocol instance of HTTPProtocol and a handler instance of HTTPRouter)
			# and the WebSockets connection
			# (with a protocol instance of WSProtocol and an instance of the Controller class set as a handler)
			def pre_connect
				# make sure this is a websocket controller
				return false unless self.class.public_instance_methods.include?(:on_message)
				# call the controller's original method, if exists, and check connection.
				return false if (defined?(super) && !super) 
				# finish if the response was sent
				return true if response.headers_sent?
				# complete handshake
				return false unless WSProtocol.new( request.service, request.service.parameters).http_handshake request, response, self
				# set up controller as WebSocket handler
				@response = WSResponse.new request
				@_accepts_broadcast = true
			end


			# WebSockets.
			#
			# stops broadcasts from being called on closed sockets that havn't been collected by the garbage collector.
			def on_disconnect
				@_accepts_broadcast = false
				super if defined? super
			end


			# # will (probably NOT), in the future, require authentication or, alternatively, return an Array [user_name, password]
			# #
			# #
			# def request_http_auth realm = false, auth = 'Digest'
			# 	return request.service.handler.hosts[request[:host] || :default].send_by_code request, 401, "WWW-Authenticate" => "#{auth}#{realm ? "realm=\"#{realm}\"" : ''}" unless request['authorization']
			# 	request['authorization']
			# end
		end

		module ClassMethods
			public

			# reviews the Redis connection and sets it up if it's missing.
			def __review_redis_connection
				return true if @@redis_sub_thread
				raise "Redis asuumed, but no Redis server is defined - define ENV['REDIS_URL'] or ENV['REDISCLOUD_URL'] to set up the Redis server's location." unless ENV["REDIS_URL"] || ENV["REDISCLOUD_URL"]
				@@redis_uri = URI.parse(ENV["REDIS_URL"] || ENV["REDISCLOUD_URL"])
				@@redis = Redis.new(host: @@redis_uri.host, port: @@redis_uri.port, password: @@redis_uri.password)
				@@redis_sub_thread = Thread.new do
					Redis.new(host: @@redis_uri.host, port: @@redis_uri.port, password: @@redis_uri.password).subscribe(self.name.to_s) do |on|
						on.message do |channel, msg|
							msg = JSON.parse(msg)
							__inner_process_broadcast nil, msg.delete(:_an_method_broadcasted), msg
						end
					end
				end
			end

			# broadcasts messages (methods) for this process
			def __inner_process_broadcast ignore, method_name, args, block
				ObjectSpace.each_object(self) { |controller| Anorexic.callback controller, method_name, *args, &block if controller.accepts_broadcast? && controller.object_id != ignore.object_id }
			end

			# broadcasts messages (methods) between all processes (using Redis).
			def __inner_redis_broadcast ignore, method_name, args, block
				return false unless defined?(Redis)
				raise "Radis broadcasts cannot accept blocks (no inter-process callbacks)" if block
				raise "Radis broadcasts accept only one paramater, which is an optional Hash (no inter-process memory sharing)" if args.length > 1 && (arg[0] && !arg[0].is_a(Hash))
				__review_redis_connection
				@@redis.publish(self.name.to_s, {_an_method_broadcasted: method_name}.merge( args[0] || {} ).to_json )
				true
			end

			# WebSockets.
			#
			# Class method.
			#
			# Use this to brodcast an event to all connections.
			#
			# accepts:
			# method_name:: a Symbol with the method's name that should respond to the broadcast.
			# *args:: any arguments that should be passed to the method (UNLESS REDIS IS USED).
			# hash:: (REDIS ONLY) any data stored in a key-value hash, that can be converted to string objects.
			#
			# the method will be called asynchrnously for each sibling instance of this Controller class.
			def broadcast method_name, *args, &block
				return false unless public_instance_methods.include?(method_name)
				__inner_redis_broadcast(nil, method_name, args, block) || __inner_process_broadcast(nil, method_name, args, block)
			end

			# WebSockets.
			#
			# Class method.
			#
			# Use this to collect data from all websockets for the calling class (websockets that have been created using the same Controller class).
			#
			# This method will call the requested method on all instance and return an Array of the returned values (including nil values).
			#
			# This method will block the excecution unless a block is passed to the method - in which case
			#  the block will used as a callback and recieve the Array as a parameter.
			#
			# i.e.
			#
			# this will block: `collect :_get_id`
			#
			# this will not block: `collect(:_get_id) {|a| puts "got #{a.length} responses."; a.each { |id| puts "#{id}"} }
			#
			# accepts:
			# method_name:: a Symbol with the method's name that should respond to the broadcast.
			# *args:: any arguments that should be passed to the method.
			# &block:: an optional block to be used as a callback.
			#
			# the method will be called asynchrnously for each instance of this Controller class.
			def collect method_name, *args, &block
				if block
					Anorexic.push_event((Proc.new() {r = []; ObjectSpace.each_object(self.class) { |controller|  r << controller.method(method_name).call(*args) if controller.accepts_broadcast? } ; r } ), &block)
					return true
				else
					r = []
					ObjectSpace.each_object(self.class) { |controller|  r << controller.method(method_name).call(*args) if controller.accepts_broadcast? }
					return r
				end
			end
		end

		module_function


	end
end