# frozen_string_literal: true

require "active_record"
require "active_support/all"
require "pathname"
require "pry"
require "rake"
require "sqlite3"

$root_dir    = GET_ME_FROM_STDIN
$js_dir      = GET_ME_FROM_STDIN
$extensions  = %w[js jsx ts tsx]
db_file_name = "diagram.sqlite3"

File.delete(db_file_name) if File.exist?(db_file_name)

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_file_name)

ActiveRecord::Schema.define do

  self.verbose = true

  create_table :local_files, force: true do |t|
    t.string :abs_path, null: false
    t.string :rel_path, null: false
    t.string :base_name, null: false
    t.string :ext
  end

  add_index :local_files, :abs_path, unique: true

  create_table :imports, force: true do |t|
    t.references :parent, foreign_key: { to_table: :local_files }, index: true, null: false
  	t.string     :parent_path, null: false
  	t.string     :import_locator, null: false
    t.string     :local_or_lib
    t.references :child, foreign_key: { to_table: :local_files }, index: true
    t.string     :child_path
  end

  add_index :imports, [:parent_path, :import_locator], unique: true
end

class LocalFile < ActiveRecord::Base
	validates :base_name, presence: true
	validates :abs_path, presence: true
	validates :rel_path, presence: true

	def all_imports    = Import.where(parent_id: id).or(Import.where(child_id: id))
	def child_imports  = Import.where(parent_id: id)
	def parent_imports = Import.where(child_id: id)

	def child_ids  = child_imports.pluck(:child_id).compact
	def parent_ids = parent_imports.pluck(:parent_id).compact

	def children = LocalFile.where(id: child_ids)
	def parents  = LocalFile.where(id: parent_ids)
end

class Import < ActiveRecord::Base
	validates :parent_path, presence: true
	validates :import_locator, presence: true, uniqueness: { scope: :parent_path }
	validates :local_or_lib, inclusion: { in: ["local", "lib"] }, allow_nil: true

	belongs_to :parent, class_name: "LocalFile"
	belongs_to :child,  class_name: "LocalFile", optional: true

	scope :lib,   -> { where(local_or_lib: "lib") }
	scope :local, -> { where(local_or_lib: "local") }
end

class ImportLine

	attr_reader :locator

	KNOWN_LIBS = %w[
		@fortawesome
		bootstrap
		datatables.net-bs4
		datatables.net-buttons-bs4
		datatables.net-rowgroup-bs4
		flatpickr
		immutable
		jquery
		jquery-ujs
		konva
		lodash
		lodash
		prop-types
		react
		react-dom
		react-input-mask
		react-konva
		react-pdf
		react-select
		select2
		tippy.js
		webpacker-react
	]

	def initialize(line, parent_abs_pathname)
		@parent_abs_pathname = parent_abs_pathname
		@line = line
		@locator = to_locator(@line)
	end

	def lib?
		return false if local?
		return true  if @locator.starts_with?("@")
		return true  if KNOWN_LIBS.include?(@locator)
		return true  if KNOWN_LIBS.any? { |lib| @locator.starts_with? "#{lib}/" }
	end

	def local?
		[
			@locator.starts_with?("./"),
			@locator.starts_with?("../"),
			@locator.starts_with?("components"),
		].any?
	end

	def multiline?
		@line.ends_with?("{\n")
	end

	def resolve_path(from:, extensions:)
		return unless local?

		base_dir = if @locator.starts_with?(".")
								@parent_abs_pathname.dirname
							else
								from
							end

		locators =  if File.extname(locator).present?
									Array(locator)
								else
									extensions.map { [locator, _1].join(".") }
								end

		locators
			.map { File.expand_path(_1, base_dir) }
			.find { File.exist?(_1) }
	end

	private

	def to_locator(line)
		line
			.split(" ")
			.last
			.delete_suffix("\n")
			.delete_suffix(";")
			.gsub("'", "")
			.gsub("\"", "")
	end

end

class AssetFile

	attr_reader :abs_pathname

	def initialize(abs_path)
		@abs_pathname = Pathname.new(abs_path)
		fail "Path must be absolute, you pass “#{abs_path}”" if @abs_pathname.relative?
	end

	def rel_pathname = abs_pathname.relative_path_from($root_dir)

	def abs_path = abs_pathname.to_s
	def rel_path = rel_pathname.to_s

	def contents = File.read(@abs_pathname)

	def import_queries
		contents.lines.select { _1.to_s.starts_with?("import") }
	end

	# @return Array<String>
	def self.files_from_dirs(dirs, extensions)
		dirs
			.map { |work_dir|
				Dir.chdir(work_dir)
				globs = extensions.map { |ext| "**/*.#{ext}" }
				Rake::FileList.new(*globs) do |fl|
					fl.exclude { `git ls-files #{_1}`.empty? }
				end
			}
			.flatten
			.uniq
			.map { File.expand_path(_1) }
			.sort
	end

end

class GVDiagram

	def initialize
		@nodes = []
		@edges = []
		@config = config_instructions
	end

	def config_instructions
		[
			%{fontname="sans-serif"},
			%{rankdir="LR"},
			%{page="130.0,130.0"},
			%{node [fontcolor="black", fontname="sans-serif", fontsize=8.0, shape=plain]},
			%{edge [arrowhead="normal", arrowsize=0.5, color="gray", fontname="sans-serif", weight=0.1]},
		]
	end

	def add_node(id:, label:, url: nil, tooltip: nil)
		attributes = { label: label, URL: url, tooltip: tooltip }
		@nodes << [
			"n#{id} [",
			attributes.select { |k, v| v.present? }.map { |(k, v)| %{#{k}="#{v}"} }.join(", "),
			"];"
		].join
	end

	def add_edge(parent_id, child_id)
		@edges << "n#{parent_id} -> n#{child_id};"
	end

	def wrapped_content
		[
			"strict digraph imports { ",
			@config.map { "  #{_1}" }.join("\n"),
			@nodes.map { "  #{_1}" }.join("\n"),
			@edges.map { "  #{_1}" }.join("\n"),
			"}",
		].join("\n")
	end

	def write_code!(output_file_path)
		@code_output_file_path = output_file_path
		Dir.chdir($root_dir)
		File.open(output_file_path, "w+") { _1 << wrapped_content }
	end

	def write_img!(output_file_path)
		ext = Pathname.new(output_file_path).extname.delete_prefix(".")
		Dir.chdir($root_dir)
		layout_engine = "dot"
		system %{dot -T#{ext} -K#{layout_engine} "#{@code_output_file_path}" -o #{output_file_path}}
	end

end


# ---

asset_files = AssetFile.files_from_dirs([$js_dir], $extensions).sort.map { AssetFile.new(_1) }

asset_files.each do |asset_file|

	rel_pathname = asset_file.rel_pathname

	LocalFile.create!(
		abs_path:  asset_file.abs_path,
		base_name: rel_pathname.basename,
		ext:       rel_pathname.extname.delete_prefix("."),
		rel_path:  asset_file.rel_path,
	)
end

asset_files.each do |asset_file|
	asset_file.import_queries.map { ImportLine.new(_1, asset_file.abs_pathname) }.each do |import_line|

		child_path = import_line.resolve_path(from: $js_dir, extensions: $extensions)

		Import.create!(
			parent:      LocalFile.find_by!(abs_path: asset_file.abs_path),
			parent_path: asset_file.rel_path,

			import_locator: import_line.locator,
			local_or_lib:  (import_line.local? ? "local" : ("lib" if import_line.lib?)),

			child:      child_path&.then { LocalFile.find_by(abs_path: _1) },
			child_path: child_path,
		)
	end
end

# puts `open \"#{}\"`

diagram = GVDiagram.new

LocalFile.all.each do |lf|
	diagram.add_node(id: lf.id, label: lf.base_name, url: nil, tooltip: lf.rel_path)
end

Import.where.not(child_id: nil).each do |im|
	diagram.add_edge(im.parent_id, im.child_id)
end

diagram.write_code!("diagram.dot")
diagram.write_img!("diagram.pdf")
