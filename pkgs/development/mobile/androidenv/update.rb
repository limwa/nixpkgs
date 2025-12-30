#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p "ruby.withPackages (ps: with ps; [ slop curb nokogiri ])"

require 'json'
require 'digest'
require 'rubygems'
require 'shellwords'
require 'erb'
require 'uri'
require 'stringio'
require 'slop'
require 'curb'
require 'nokogiri'
# 
# "archives": [
#   {
#     "arch": "all",
#     "os": "windows",
#     "sha1": "fc165c721b8d2da55e6fede467526c81f562be7b",
#     "size": 54254759,
#     "url": "https://dl.google.com/android/repository/91936d4ee3ccc839f0addd53c9ebf087b1e39251.build-tools_r30.0.3-windows.zip"
#   },
#   {
#     "arch": "all",
#     "os": "linux",
#     "sha1": "2076ea81b5a2fc298ef7bf85d666f496b928c7f1",
#     "size": 53134793,
#     "url": "https://dl.google.com/android/repository/build-tools_r30.0.3-linux.zip"
#   },
#   {
#     "arch": "all",
#     "os": "macosx",
#     "sha1": "0807cd3f0dbc33c8be7f3d6faa263f6b14b502b7",
#     "size": 51698282,
#     "url": "https://dl.google.com/android/repository/f6d24b187cc6bd534c6c37604205171784ac5621.build-tools_r30.0.3-macosx.zip"
#   }
# ],
# "channel": "stable",
# "kind": "generic",
# "license": "android-sdk-license#aaf80cd0aee7e569",
# "path": "build-tools;30.0.3",
# "revision": "30.0.3"*/

class Archive
  attr_reader :arch, :os, :sha1, :size, :url
  
  # @param arch [String]
  def initialize(arch)
  end
end

a = Archive.new(
  arch: 'all',
  os: 'windows'
)

class Package
  attr_reader :archives, :channel, :kind, :license, :path, :revision

  def initialize(params = {})
    # @type [Array<Archive>]
    @archives = []
    # @type [String]
    @channel = params[:channel] || (raise 'channel is required')
    # @type [String]
    @kind = params[:kind] || (raise 'kind is required')
    # @type [String]
    @license = params[:license] || (raise 'license is required')
    # @type
    @path = params[:path] || (raise 'path is required')
    @revision = params[:revision] || (raise 'revision is required')
    
    
    
    
  end
end

class PackageCollection
  attr_reader :revisions

  def initialize
    @revisions = {}
  end
end

class Repository
  attr_reader :packages, :expirations, :licenses

  def initialize
    @packages = {}
    @expirations = {}
    @licenses = {}
  end

  # @param path [String]
  # @return [PackageCollection, nil]
  def get_package_collection path
    @packages[path]
  end
  
  # @param package [Package]
  def add_package package
    path = package.p
  end
  
  def filter_packages
    raise "No block given to filter_packages" unless block_given?
    @packages.filter yield
  end
end

r = Repository.new

r.filter_packages do |a, b|
end

# Returns a repo URL for a given package name.
def repo_url value
  if value && value.start_with?('http')
    value
  elsif value
    "https://dl.google.com/android/repository/#{value}"
  else
    nil
  end
end

# Returns a system image URL for a given system image name.
def image_url value, dir
  if dir == "default"
    dir = "android"
  end
  if value && value.start_with?('http')
    value
  elsif value
    "https://dl.google.com/android/repository/sys-img/#{dir}/#{value}"
  else
    nil
  end
end

# Runs a GET with curl.
def _curl_get url
  curl = Curl::Easy.new(url) do |http|
    http.headers['User-Agent'] = 'nixpkgs androidenv update bot'
    yield http if block_given?
  end
  STDERR.print "GET #{url}"
  curl.perform
  STDERR.puts "... #{curl.response_code}"

  StringIO.new(curl.body_str)
end

# Retrieves a repo from the filesystem or a URL.
def get location
  uri = URI.parse(location)
  case uri.scheme
  when 'repo'
    _curl_get repo_url("#{uri.host}#{uri.fragment}.xml")
  when 'image'
    _curl_get image_url("sys-img#{uri.fragment}.xml", uri.host)
  else
    if File.exist?(uri.path)
      File.open(uri.path, 'rt')
    else
      raise "Repository #{uri} was neither a file nor a repo URL"
    end
  end
end

def make_key elements
  elements.join('#')
end

def decode_key key
  key.split('#')
end

def revision_to_s revision_element
  return nil unless revision_element
  
  major = text revision_element.at_css('> major')
  minor = text revision_element.at_css('> minor')
  micro = text revision_element.at_css('> micro')
  preview = text revision_element.at_css('> preview')

  # Converting the revision to a string must obey a few
  # rules to ensure that sorting the resulting string
  # is consistent with the expected ordering of the revisions
  # in the repository.

  revision = major
  # Minor and micro are assumed to be 0 if not present.
  # This would be a problem if, for instance,
  # the revision "20" is considered newer than "20.0",
  # which doesn't seem to be the case.
  revision << ".#{minor || '0'}"
  revision << ".#{micro || '0'}"
  # The preview number is optionally included in the revision
  # because "20.0" is considered newer than "20.0-preview01",
  # for instance.
  revision << "-preview#{preview}" unless empty?(preview)

  revision
end

def package_details package
  type_details = package.at_css('> type-details')
  type = type_details.attributes['type']
  type &&= type.value
  return nil if type.nil?

  kind = case type
    when 'generic:genericDetailsType'
      'generic'
    when 'addon:extraDetailsType'
      'extra'
    when 'addon:addonDetailsType'
      'addon'
    when 'sdk:platformDetailsType'
      'platform'
    when 'sdk:sourceDetailsType'
      'source'
    when 'sys-img:sysImgDetailsType'
      'system-image'
    else
      raise "Unknown package type: #{type}"
  end

  api_level = text type_details.at_css('> api-level')
  abi = text type_details.at_css('> abi')
  extension_level = text type_details.at_css('> extension-level')

  base_extension = text type_details.at_css('> base-extension')
  base_extension &&= base_extension == 'true'

  layoutlib = type_details.at_css('> layoutlib')
  layoutlib &&= layoutlib.attributes

  details = {}
  details['api_level'] = api_level if api_level
  details['base_extension'] = base_extension if base_extension
  details['extension_level'] = extension_level if extension_level
  details['layoutlib'] = layoutlib if layoutlib
  details['abi'] = abi if abi
  
  [kind, details]
end

# Returns a hash of archives for the specified package node.
def package_archives package
  archives = []
  package.css('> archives > archive').each do |archive|
    host_os = text archive.at_css('> host-os')
    host_arch = text archive.at_css('> host-arch')
    host_os = 'all' if empty?(host_os)
    host_arch = 'all' if empty?(host_arch)
    archives += [{
      'os' => host_os,
      'arch' => host_arch,
      'size' => Integer(text(archive.at_css('> complete > size'))),
      'sha1' => text(archive.at_css('> complete > checksum')),
      'url' => yield(text(archive.at_css('> complete > url')))
    }]
  end
  archives
end

def package_dependencies package
  dependencies = []
  package.css('> dependencies > dependency').each do |dependency|
    result = {}

    path = dependency.attributes['path']
    path &&= path.value

    min_revision = revision_to_s dependency.at_css('> min-revision')

    result['path'] = path
    result['min-revision'] = min_revision if min_revision

    dependencies << result
  end

  dependencies
end

# Returns the text from a node, or nil.
def text node
  node ? node.text : nil
end

# Nil or empty helper.
def empty? value
  !value || value.empty?
end

# Today since Unix Epoch, January 1, 1970.
def today
  Time.now.utc.to_i / 24 / 60 / 60
end

# The expiration strategy. Expire if the last available day was before the `oldest_valid_day`.
def expire_records record, oldest_valid_day
  if record.is_a?(Hash)
    if record.has_key?('last-available-day') &&
      record['last-available-day'] < oldest_valid_day
      return nil
    end
    update = {}
    record.each {|key, value|
      v = expire_records value, oldest_valid_day
      update[key] = v if v
    }
    update
  else
    record
  end
end

# Normalize the specified license text.
# See: https://brash-snapper.glitch.me/ for how the munging works.
def normalize_license license
  license = license.dup
  license.gsub!(/([^\n])\n([^\n])/m, '\1 \2')
  license.gsub!(/ +/, ' ')
  license.strip!
  license
end

# Gets all license texts, deduplicating them.
def get_licenses doc
  licenses = {}
  key_lookup = {}
  doc.css('license[type="text"]').each do |license_node|
    license_id = license_node['id']
    license_text = normalize_license(text(license_node))
    license_hash = Digest::SHA256.hexdigest(license_text)[0...16]

    target = (licenses[license_id] ||= {})
    target['revisions'] ||= {}
    target['revisions'][license_hash] = license_text

    key_lookup[license_id] = make_key [license_id, license_hash]
  end
  [licenses, key_lookup]
end

def get_channels doc
  channels = {}
  doc.css('channel').each do |channel_node|
    channel_id = channel_node['id']
    channels[channel_id] = text(channel_node) if channel_id
  end
  channels
end

def parse_repository_xml doc
  licenses, license_key_lookup = get_licenses doc
  channels = get_channels doc
  packages = {}
  expirations = {}

  doc.css('remotePackage').each do |package|
    uses_license = package.at_css('> uses-license')
    uses_license &&= uses_license['ref']

    channel_ref = package.at_css('> channelRef')
    channel_ref &&= channel_ref['ref']
    channel_ref &&= channels[channel_ref]

    obsolete = package['obsolete']

    revision = revision_to_s package.at_css('> revision')
    kind, details = package_details(package)
    archives = package_archives(package) { |url| repo_url url }
    dependencies = package_dependencies package

    # @type [String]
    path = package['path']

    target = (packages[path] ||= {})
    target['revisions'] ||= {}
    target_revision = (target['revisions'][revision] = {})

    target_revision['kind'] = kind
    target_revision['path'] = path
    target_revision['revision'] = revision
    target_revision['channel'] = channel_ref
    target_revision['license'] = license_key_lookup[uses_license] if uses_license
    target_revision['obsolete'] = true if obsolete == 'true'
    target_revision['details'] = details unless details.empty?
    target_revision['dependencies'] = dependencies unless dependencies.empty?
    target_revision['archives'] = archives
    target_revision['last-available-day'] = today
  end

  [licenses, packages, expirations]
end

# Make the clean diff by always sorting the result before puting it in the stdout.
def sort_recursively value
  if value.is_a?(Hash)
    Hash[
      value.map do |k, v|
        [k, sort_recursively(v)]
      end.sort_by {|(k, v)| k }
    ]
  elsif value.is_a?(Array)
    value.map do |v| sort_recursively(v) end
  else
    value
  end
end

def merge_recursively a, b
  a.merge!(b) {|key, a_item, b_item|
    if a_item.is_a?(Hash) && b_item.is_a?(Hash)
      merge_recursively(a_item, b_item)
    elsif b_item != nil
      b_item
    end
  }
  a
end

def merge dest, src
  merge_recursively dest, src
end

opts = Slop.parse do |o|
  o.array '-r', '--repositories', 'packages repo XMLs to parse', default: %w[
    repo://repository#2-3
    repo://addon#2-3
    image://android#2-3
    image://android-tv#2-3
    image://android-wear#2-3
    image://android-wear-cn#2-3
    image://android-automotive#2-3
    image://google_apis#2-3
    image://google_apis_playstore#2-3
  ]
  o.string '-I', '--input', 'input JSON file for repo', default: File.join(__dir__, 'repo.json')
  o.string '-O', '--output', 'output JSON file for repo', default: File.join(__dir__, 'repo.json')
end

result = {
  'packages' => {},
  'expirations' => {},
  'licenses' => {},
}

opts[:repositories].each do |filename|
  licenses, packages, expirations = parse_repository_xml(Nokogiri::XML(get(filename)) { |conf| conf.noblanks })
  merge result['packages'], packages
  merge result['expirations'], expirations
  merge result['licenses'], licenses
end

input = {}
begin
  input_json = if File.exist?(opts[:input])
                 STDERR.puts "Reading #{opts[:input]}"
                 File.read(opts[:input])
               else
                 STDERR.puts "Creating new repo"
                 "{}"
               end
  input = JSON.parse(input_json)
rescue JSON::ParserError => e
  STDERR.write(e.message)
  return
end

# Regular installation of Android SDK would keep the previously installed packages even if they are not
# in the uptodate XML files, so here we try to support this logic by keeping un-available packages,
# therefore the old packages will work as long as the links are working on the Google servers.
merged_result = merge(input, result)

# Over time, as new revisions and packages are added, we want to
# prune old revisions and packages so that the repo.json file
# doesn't grow indefinitely.
# So with this variable we claim it's okay to remove them from the
# JSON after two years that they are not available.
two_years_ago = today - 2 * 365

expired_result = merged_result


output = sort_recursively(expired_result)



# Fingerprint the latest versions.
# fingerprint = Digest::SHA256.hexdigest(output['latest'].tap {_1.delete 'fingerprint'}.to_json)[0...16]
# output['latest']['fingerprint'] = fingerprint

# Write the repository. Append a \n to keep nixpkgs Github Actions happy.
STDERR.puts "Writing #{opts[:output]}"
File.write opts[:output], (JSON.pretty_generate(output) + "\n")

# Output metadata for the nixpkgs update script.
if ENV['UPDATE_NIX_ATTR_PATH']
  # See if there are any changes in the latest versions.
  cur_latest = output['latest'] || {}

  old_versions = []
  new_versions = []
  changes = []
  changed = false

  cur_latest.each do |k, v|
    prev = prev_latest[k]
    if k != 'fingerprint' && prev && prev != v
      old_versions << "#{k}:#{prev}"
      new_versions << "#{k}:#{v}"
      changes << "#{k}: #{prev} -> #{v}"
      changed = true
    end
  end

  changed_paths = []
  if changed
    # Instantiate it.
    test_result = `NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1 nix-build #{Shellwords.escape(File.realpath(File.join(__dir__, '..', '..', '..', '..', 'default.nix')))} -A #{Shellwords.join [ENV['UPDATE_NIX_ATTR_PATH']]} 2>&1`
    test_status = $?.exitstatus

    template = ERB.new(<<-EOF, trim_mode: '<>-')
androidenv: <%= changes.join('; ') %>

Performed the following automatic androidenv updates:

<% changes.each do |change| %>
- <%= change -%>
<% end %>

Tests exited with status: <%= test_status -%>

<% if !test_result.empty? %>
Last 100 lines of output:
```
<%= test_result.lines.last(100).join -%>
```
<% end %>
EOF

    changed_paths << {
      attrPath: 'androidenv.androidPkgs.androidsdk',
      oldVersion: old_versions.join('; '),
      newVersion: new_versions.join('; '),
      files: [
        opts[:output]
      ],
      commitMessage: template.result(binding)
    }
  end

  # nix-update info is on stdout
  STDOUT.puts JSON.pretty_generate(changed_paths)
end
