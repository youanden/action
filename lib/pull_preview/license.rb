# The MIT License (MIT)
# 
# Copyright (c) 2015 GitLab B.V.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require "openssl"
require "date"
require "json"
require "base64"

require_relative "license/encryptor"
require_relative "license/boundary"

module PullPreview
  class License
    class Error < StandardError; end
    class ImportError < Error; end
    class ValidationError < Error; end

    class << self
      attr_reader :encryption_key
      @encryption_key = nil

      def encryption_key=(key)
        if key && !key.is_a?(OpenSSL::PKey::RSA)
          raise ArgumentError, "No RSA encryption key provided."
        end

        @encryption_key = key
        @encryptor = nil
      end

      def encryptor
        @encryptor ||= Encryptor.new(self.encryption_key)
      end

      def load_key!(key_type)
        return if key_type == :private && @encryption_key&.private?
        return if key_type == :public  && @encryption_key&.public?
        # Note: public? is always true with RSA

        filename = "license_key"
        filename += ".pub" if key_type == :public

        key_data = PullPreview.root_dir.join(filename).read
        PullPreview::License.encryption_key = OpenSSL::PKey::RSA.new key_data
      end

      def import!
        load_key! :public

        data = ENV.fetch("PULLPREVIEW_LICENSE", nil)
        if data.nil?
          PullPreview.logger.error "Missing PULLPREVIEW_LICENSE environment variable."
        end

        data = Boundary.remove_boundary(data)

        begin
          license_json = encryptor.decrypt(data)
        rescue Encryptor::Error
          PullPreview.logger.error "License data could not be decrypted."
        end

        begin
          attributes = JSON.parse(license_json)
        rescue JSON::ParseError
          PullPreview.logger.error "License data is invalid JSON."
        end

        license = new(attributes)
        
        PullPreview.logger.info "Imported license:"
        PullPreview.logger.info license

        license
      end

      def check!(command)
        case command
        when "github-sync"
          if import!()&.expired?
            PullPreview.logger.error "License expired"
            exit 1
          end
        end
      end
    end

    attr_accessor :attributes

    def initialize(attributes = {})
      @attributes = attributes.transform_keys(&:to_s).slice("type", "expires_at")
    end

    def valid?
      return !validation_error
    end

    def validation_error
      return "no attributes"            unless self.attributes
      return "attributes is not a hash" unless self.attributes.is_a?(Hash)
      return "no type attribute"        unless self.attributes.key?("type")

      case self.attributes['type']
      when "trial"
        return "no trial expiration date" unless self.attributes.key?("expires_at")
        return "trial expiration date is not a date" unless self.attributes["expires_at"].is_a?(Date)
        return "extraneous attributes" unless self.attributes.size == 2
      else
        return "unexpected type: #{self.attributes["type"]}"
      end
    end

    def validate!
      raise ValidationError, "License is invalid: #{validation_error}" unless valid?
    end

    def expired?
      self.attributes["expires_at"] && Date.today >= Date.parse(self.attributes["expires_at"])
    end

    def to_s
      JSON.pretty_generate(self.attributes)
    end

    def to_json
      JSON.dump(self.attributes)
    end

    def export(boundary: nil)
      validate!

      self.class.load_key! :private

      data = self.class.encryptor.encrypt(self.to_json)

      if boundary
        data = Boundary.add_boundary(data, boundary)
      end

      data
    end
  end
end
