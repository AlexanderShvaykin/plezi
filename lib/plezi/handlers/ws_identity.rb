module Plezi

	module Base

		module WSObject

			# the following are additions to the WebSocket Object module,
			# to establish identity to websocket realtionships, allowing for a
			# websocket message bank.

			module InstanceMethods
				protected

				# The following method registers the connections as a unique global identity.
				#
				# Like {Plezi::Base::WSObject::SuperClassMethods#notify}, using this method requires an active Redis connection
				# to be set up. See {Plezi#redis} for more information.
				#
				# Only one connection at a time can respond to identity events. If the same identity
				# connects more than once, only the last connection will receive the notifications.
				#
				# The method accepts:
				# identity:: a global application wide unique identifier that will persist throughout all of the identity's connections.
				# options:: an option's hash that sets the properties of the identity.
				#
				# The option's Hash, at the moment, accepts only the following (optional) options:
				# lifetime:: sets how long the identity can survive. defaults to `604_800` seconds (7 days).
				# max_connections:: sets the amount of concurrent connections an identity can have (akin to open browser tabs receiving notifications). defaults to 1 (a single connection).
				#
				# Calling this method will also initiate any events waiting in the identity's queue.
				# make sure that the method is only called once all other initialization is complete.
				#
				# Do NOT call this method asynchronously unless Plezi is set to run as in a single threaded mode - doing so
				# will execute any pending events outside the scope of the IO's mutex lock, thus introducing race conditions.
				def register_as identity, options = {}
					redis = Plezi.redis
					raise "The identity API requires a Redis connection" unless redis
					options[:max_connections] ||= 1
					options[:max_connections] = 1 if options[:max_connections].to_i < 1
					options[:lifetime] ||= 604_800
					identity = identity.to_s.freeze
					@___identity ||= [].to_set
					@___identity << identity
					redis.pipelined do
						redis.lpush "#{identity}_uuid".freeze, uuid
						redis.ltrim "#{identity}_uuid".freeze, 0, (options[:max_connections]-1)
					end
					___review_identity identity
					redis.lpush(identity, ''.freeze) unless redis.llen(identity) > 0
					redis.pipelined do
						redis.expire identity, options[:lifetime]
						redis.expire "#{identity}_uuid".freeze, options[:lifetime]
					end
				end

				# sends a notification to an Identity. Returns false if the Identity never registered or it's registration expired.
				def notify identity, event_name, *args
					self.class.notify identity, event_name, *args
				end
				# returns true if the Identity in question is registered to receive notifications.
				def registered? identity
					self.class.registered? identity
				end
			end
			module ClassMethods
			end
			module SuperInstanceMethods
				protected
				def ___review_identity identity
					redis = Plezi.redis
					raise "unknown Redis initiation error" unless redis
					identity = identity.to_s.freeze
					return Iodine.warn("Identity message reached wrong target (ignored).").clear unless @___identity.include?(identity)
					messages = redis.multi do
						redis.lrange identity, 1, -1
						redis.ltrim identity, 0, 0
					end[0]
					targets = redis.lrange "#{identity}_uuid", 0, -1
					while msg = messages.shift
						msg = ::Plezi::Base::WSObject.translate_message(msg)
						next unless msg
						Iodine.error("Notification recieved but no method can handle it - dump:\r\n #{msg.to_s}") && next unless self.class.has_super_method?(msg[:method])
						targets.each {|target| target == uuid ? self.method(msg[:method]).call(*msg[:data]) : unicast(target, msg[:method], *msg[:data])}
						
					end
				end
			end

			module SuperClassMethods
				public

				# sends a notification to an Identity. Returns false if the Identity never registered or it's registration expired.
				def notify identity, event_name, *args
					redis = Plezi.redis
					raise "The identity API requires a Redis connection" unless redis
					identity = identity.to_s.freeze
					return false unless redis.llen(identity).to_i > 0
					redis.rpush identity, ({method: event_name, data: args}).to_yaml
					target_uuid = redis.lindex "#{identity}_uuid".freeze, 0
					unicast target_uuid, :___review_identity, identity if target_uuid
					true
				end

				# returns true if the Identity in question is registered to receive notifications.
				def registered? identity
					redis = Plezi.redis
					return Iodine.warn("Cannot check for Identity registration without a Redis connection (silent).") && false unless redis
					identity = identity.to_s.freeze
					redis.llen(identity).to_i > 0
				end
			end
		end
	end
end
