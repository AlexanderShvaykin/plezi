#!/usr/bin/env ruby
# encoding: UTF-8

# Using pathname extentions for setting public folder
require 'pathname'

#set up root object, it will be used by the environment and\or the anorexic extension gems.
Root ||= Pathname.new(File.dirname(__FILE__)).expand_path

# load all framework and gems
require ::File.expand_path(File.join("..", "environment.rb"),  __FILE__)

# start a web service to listen on the first default port (3000 or the port set by the command-line).
listen root: Root.join('public').to_s


# This is an optional re-write route for I18n - Set it up in the ./config/i18n_config.rb file
route "*" , I18nReWrite if defined? I18n


# remove this demo route and add your routes here:
# this route accepts any /:id and the :id is mapped to: params["id"] (available as params[:id] as well.)
shared_route '/', SampleController #, debug: true


# this is a catch all route
# route('*') { |req, res| res.body << "Hello World!" }
