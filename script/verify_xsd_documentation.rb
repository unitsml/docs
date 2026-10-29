# frozen_string_literal: true

require "rexml/document"
require "rexml/xpath"
require "set"

schema_path = ARGV.fetch(0)
output_path = ARGV.fetch(1)
schema = REXML::Document.new(File.read(schema_path))
ns = { "xsd" => "http://www.w3.org/2001/XMLSchema" }
components = %w[element complexType attributeGroup].flat_map do |kind|
  REXML::XPath.match(schema, "/xsd:schema/xsd:#{kind}", ns)
end
expected = components.map { |component| "xsd_#{component.attributes.fetch('name')}" }.to_set
abort "No schema components found in #{schema_path}" if expected.empty?

files = File.directory?(output_path) ? Dir.glob(File.join(output_path, "**", "*.html")) : [output_path]
files.each do |file|
  html = File.read(file)
  anchors = html.scan(/\bid=["']([^"']+)["']/).flatten.to_set
  next unless expected.subset?(anchors)

  if html.match?(/\{%\s*(?:for|render|endfor)\b|Liquid (?:syntax )?error:/)
    abort "Unrendered or failed Liquid in #{file}"
  end

  puts "Verified #{expected.size} schema component anchors in #{file}"
  exit 0
end
abort "No generated HTML in #{output_path} contains all #{expected.size} schema component anchors"
