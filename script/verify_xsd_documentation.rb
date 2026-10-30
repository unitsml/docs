# frozen_string_literal: true

require "rexml/document"
require "rexml/xpath"
require "set"
require "svg_conform"
require "nokogiri"

schema_path = ARGV.fetch(0)
output_path = ARGV.fetch(1)
schema = REXML::Document.new(File.read(schema_path))
ns = { "xsd" => "http://www.w3.org/2001/XMLSchema" }
components = %w[element complexType attributeGroup].flat_map do |kind|
  REXML::XPath.match(schema, "/xsd:schema/xsd:#{kind}", ns)
end
expected = components.map { |component| "xsd_#{component.attributes.fetch('name')}" }.to_set
abort "No schema components found in #{schema_path}" if expected.empty?

validator = SvgConform::Validator.new(mode: :sax)
profile = SvgConform::Profiles.get(:metanorma)
engine = SvgConform::RemediationEngine.new(profile)
svg_directory = ARGV[2] || File.expand_path("../_plantuml_images", File.dirname(schema_path))

files = File.directory?(output_path) ? Dir.glob(File.join(output_path, "**", "*.html")) : [output_path]
files.each do |file|
  html = File.read(file)
  document = Nokogiri::HTML5(html)
  identifiers = document.xpath("//*[@id]").map { |node| node["id"] }
  anchors = identifiers.to_set
  next unless expected.subset?(anchors)
  abort "Duplicate HTML identifiers in #{file}" unless identifiers.size == anchors.size

  if html.match?(/\{%\s*(?:for|render|endfor)\b|Liquid (?:syntax )?error:/)
    abort "Unrendered or failed Liquid in #{file}"
  end

  diagrams = document.xpath("//*[local-name()='svg']")
  abort "Expected #{expected.size} SVG structure diagrams, found #{diagrams.size} in #{file}" unless diagrams.size == expected.size

  diagram_roots = diagrams.map do |diagram|
    abort "PlantUML error diagram in #{file}" if diagram.text.match?(/Syntax Error|An error has occurred/i)
    links = diagram.xpath(".//*[local-name()='a']").filter_map do |node|
      href = node["href"] || node.attribute_with_ns("href", "http://www.w3.org/1999/xlink")&.value
      href.delete_prefix("#") if href&.start_with?("#")
    end
    missing = links.reject { |target| anchors.include?(target) }
    abort "Broken SVG component links: #{missing.uniq.join(', ')}" unless missing.empty?
    links.grep(/\Axsd_/).first
  end
  missing_diagrams = expected - diagram_roots.to_set
  abort "Missing linked SVG component roots: #{missing_diagrams.to_a.join(', ')}" unless missing_diagrams.empty?

  # Validate native assets before HTML-specific IDs and attributes are injected.
  # Apply the same configured remediations as Metanorma, without writing files.
  expected.sort.each do |anchor|
    svg_file = File.join(svg_directory, "#{anchor.sub('xsd_', 'xsd-')}.svg")
    abort "Missing native SVG: #{svg_file}" unless File.file?(svg_file)
    native = SvgConform::Document.from_file(svg_file)
    result = validator.validate(native.root, profile: profile)
    engine.apply_remediations(native, result)
    result = validator.validate(native.root, profile: profile)
    invalid = result.errors.reject { |error| error.violation_type == :reference_violation }
    abort "SVG conformance errors in #{svg_file}: #{invalid.map(&:message).uniq.join('; ')}" unless invalid.empty?
    unresolved = result.unresolved_internal_references.reject { |reference| anchors.include?(reference.target_id) }
    abort "Broken SVG references in #{svg_file}: #{unresolved.map(&:value).uniq.join(', ')}" unless unresolved.empty?
  end

  puts "Verified #{expected.size} schema component anchors and #{diagrams.size} linked SVG diagrams in #{file}"
  exit 0
end
abort "No generated HTML in #{output_path} contains all #{expected.size} schema component anchors"
