#!/usr/bin/env ruby
# Documentation register validator: includes, orphans, front matter,
# cross-part citations, metanorma.yml consistency.

require "yaml"

SERIES_TITLE = { "unitsml" => "UnitsML", "plurimath" => "Plurimath",
                 "asciimath" => "asciimath", "pma" => "pma" }.freeze
SERIES_RANGE = { "unitsml" => 1..8, "plurimath" => 1..4,
                 "asciimath" => 1..2, "pma" => 1..1 }.freeze
REQUIRED_SECTIONS = %w[00-foreword 00-introduction 01-scope 02-norm-refs
                       03-terms 04-conventions 99-bibliography].freeze
LEGACY = %w[unitsml-guide unitsml-incorporation unitsml-ubl-ndr-subset].freeze
# Frozen v1 committee drafts (CalConnect 36810/36811): structure is not
# retroactively conformed; nn-usage.adoc was never included — known v1 artifact.
FROZEN_V1 = %w[asciiunits unitsdb].freeze
ROOTS = ARGV.empty? ? [File.expand_path("..", __dir__)] : ARGV

problems = Hash.new { |h, k| h[k] = [] }
report = ->(key, msg) { (problems[key] ||= []) << msg }

# ---- pass 1: per-register structure ------------------------------------------
all_dirs = {}

ROOTS.each do |root|
  key = root
  begin
    mn = YAML.safe_load(File.read(File.join(root, "metanorma.yml")))
  rescue StandardError => e
    report.call(key, "metanorma.yml unparseable: #{e.message[0, 80]}")
    mn = { "metanorma" => { "source" => { "files" => [] } } }
  end
  listed_dirs = (mn.dig("metanorma", "source", "files") || []).map { |f| File.dirname(f) }

  dirs = Dir.glob(File.join(root, "sources", "*"))
            .select { |d| File.directory?(d) && File.exist?(File.join(d, "document.adoc")) }
            .sort
  all_dirs[root] = dirs

  dirs.each do |d|
    name = File.basename(d)
    rel = d.sub("#{root}/", "")
    legacy = LEGACY.any? { |l| name.start_with?(l) }

    unless legacy || listed_dirs.include?(rel)
      report.call(key, "#{name}: present on disk but not listed in metanorma.yml")
    end

    includes = File.read(File.join(d, "document.adoc"))
                   .scan(/include::([^#\[]+?)\[\]/).map(&:first)
    includes.each do |inc|
      report.call(key, "#{name}: dangling include #{inc}") unless File.exist?(File.join(d, inc))
    end

    sec_dir = File.join(d, "sections")
    next unless File.directory?(sec_dir)
    next if FROZEN_V1.include?(name)
    included = includes.map { |i| File.basename(i) }
    Dir.glob(File.join(sec_dir, "*.adoc")).each do |f|
      base = File.basename(f)
      report.call(key, "#{name}: orphan section #{base}") unless included.include?(base)
    end
  end

  (listed_dirs - dirs.map { |d| d.sub("#{root}/", "") }).each do |rel|
    report.call(key, "metanorma.yml lists missing document: #{rel}")
  end
end

# ---- pass 2: per-document content (series parts only) ------------------------
ROOTS.each do |root|
  key = root
  all_dirs[root].each do |d|
    name = File.basename(d)
    next if LEGACY.any? { |l| name.start_with?(l) }
    next unless name =~ /\A(#{SERIES_TITLE.keys.join("|")})-(\d+)-/
    series = Regexp.last_match(1)
    num = Regexp.last_match(2).to_i
    doc = File.read(File.join(d, "document.adoc"))

    report.call(key, "#{name}: docnumber mismatch") unless doc =~ /^:docnumber: #{num}$/
    report.call(key, "#{name}: :title-intro-en: is not the series name") unless doc =~ /^:title-intro-en: #{SERIES_TITLE[series]}$/
    unless SERIES_RANGE[series].cover?(num)
      report.call(key, "#{name}: part number #{num} outside series range")
    end
    REQUIRED_SECTIONS.each do |s|
      report.call(key, "#{name}: missing required section #{s}") unless File.exist?(File.join(d, "sections", "#{s}.adoc"))
    end
    report.call(key, "#{name}: missing conformance clause") unless doc.include?("conformance.adoc[]")
  end
end

# ---- pass 3: cross-part citations resolve ------------------------------------
all_names = all_dirs.values.flatten.map { |d| File.basename(d) }
# Only check citations to series visible in the scanned registers; a sibling
# register (plurimath/docs) may not be checked out in this repo's CI.
known_series = all_names.map { |n| n.split("-").first }.uniq

all_dirs.each do |root, dirs|
  dirs.each do |d|
    name = File.basename(d)
    doc = Dir.glob([File.join(d, "*.adoc"), File.join(d, "sections", "*.adoc")])
             .map { |f| File.read(f) }.join("\n")
    doc.scan(/\b(UnitsML|Plurimath|asciimath|pma) (\d+)\b/) do |cited_series, cited_num|
      next unless known_series.include?(cited_series.downcase)
      target = "#{cited_series.downcase}-#{cited_num}-"
      next if all_names.any? { |n| n.start_with?(target) }
      report.call(root, "#{name}: citation to non-existent part #{cited_series} #{cited_num}")
    end
  end
end

total = problems.values.map(&:size).sum
if total.zero?
  puts "VALIDATION OK: no problems found across #{ROOTS.length} registers (#{all_dirs.values.map(&:length).sum} documents)"
else
  problems.each do |key, list|
    puts "== #{key}"
    list.each { |p| puts "  - #{p}" }
  end
  puts "TOTAL PROBLEMS: #{total}"
  exit 1
end
