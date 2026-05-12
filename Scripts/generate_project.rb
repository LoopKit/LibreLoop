#!/usr/bin/env ruby
# Regenerates LibreLoop.xcodeproj from source layout.
# Run from the repo root: ruby Scripts/generate_project.rb

require 'xcodeproj'
require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(REPO_ROOT, 'LibreLoop.xcodeproj')

FileUtils.rm_rf(PROJECT_PATH)
proj = Xcodeproj::Project.new(PROJECT_PATH)

# ---------------------------------------------------------------------------
# Project-level build settings (modeled on G7SensorKit, bumped to iOS 17)
# ---------------------------------------------------------------------------
common_settings = {
  'ALWAYS_SEARCH_USER_PATHS' => 'NO',
  'CLANG_ANALYZER_NONNULL' => 'YES',
  'CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION' => 'YES_AGGRESSIVE',
  'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++20',
  'CLANG_ENABLE_MODULES' => 'YES',
  'CLANG_ENABLE_OBJC_ARC' => 'YES',
  'CLANG_ENABLE_OBJC_WEAK' => 'YES',
  'CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING' => 'YES',
  'CLANG_WARN_BOOL_CONVERSION' => 'YES',
  'CLANG_WARN_COMMA' => 'YES',
  'CLANG_WARN_CONSTANT_CONVERSION' => 'YES',
  'CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS' => 'YES',
  'CLANG_WARN_DIRECT_OBJC_ISA_USAGE' => 'YES_ERROR',
  'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'YES',
  'CLANG_WARN_EMPTY_BODY' => 'YES',
  'CLANG_WARN_ENUM_CONVERSION' => 'YES',
  'CLANG_WARN_INFINITE_RECURSION' => 'YES',
  'CLANG_WARN_INT_CONVERSION' => 'YES',
  'CLANG_WARN_NON_LITERAL_NULL_CONVERSION' => 'YES',
  'CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF' => 'YES',
  'CLANG_WARN_OBJC_LITERAL_CONVERSION' => 'YES',
  'CLANG_WARN_OBJC_ROOT_CLASS' => 'YES_ERROR',
  'CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER' => 'YES',
  'CLANG_WARN_RANGE_LOOP_ANALYSIS' => 'YES',
  'CLANG_WARN_STRICT_PROTOTYPES' => 'YES',
  'CLANG_WARN_SUSPICIOUS_MOVE' => 'YES',
  'CLANG_WARN_UNGUARDED_AVAILABILITY' => 'YES_AGGRESSIVE',
  'CLANG_WARN_UNREACHABLE_CODE' => 'YES',
  'CLANG_WARN__DUPLICATE_METHOD_MATCH' => 'YES',
  'COPY_PHASE_STRIP' => 'NO',
  'CURRENT_PROJECT_VERSION' => '1',
  'ENABLE_STRICT_OBJC_MSGSEND' => 'YES',
  'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
  'GCC_NO_COMMON_BLOCKS' => 'YES',
  'GCC_WARN_64_TO_32_BIT_CONVERSION' => 'YES',
  'GCC_WARN_ABOUT_RETURN_TYPE' => 'YES_ERROR',
  'GCC_WARN_UNDECLARED_SELECTOR' => 'YES',
  'GCC_WARN_UNINITIALIZED_AUTOS' => 'YES_AGGRESSIVE',
  'GCC_WARN_UNUSED_FUNCTION' => 'YES',
  'GCC_WARN_UNUSED_VARIABLE' => 'YES',
  'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
  'LOCALIZATION_PREFERS_STRING_CATALOGS' => 'YES',
  'LOCALIZED_STRING_MACRO_NAMES' => ['NSLocalizedString', 'CFCopyLocalizedString', 'LocalizedString'],
  'MTL_FAST_MATH' => 'YES',
  'SWIFT_VERSION' => '5.0',
  'VERSIONING_SYSTEM' => 'apple-generic',
  'VERSION_INFO_PREFIX' => '',
}

debug_only = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf',
  'ENABLE_NS_ASSERTIONS' => 'YES',
  'ENABLE_TESTABILITY' => 'YES',
  'GCC_DYNAMIC_NO_PIC' => 'NO',
  'GCC_OPTIMIZATION_LEVEL' => '0',
  'GCC_PREPROCESSOR_DEFINITIONS' => ['DEBUG=1', '$(inherited)'],
  'MTL_ENABLE_DEBUG_INFO' => 'INCLUDE_SOURCE',
  'ONLY_ACTIVE_ARCH' => 'YES',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'DEBUG',
  'SWIFT_OPTIMIZATION_LEVEL' => '-Onone',
}

release_only = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
  'ENABLE_NS_ASSERTIONS' => 'NO',
  'MTL_ENABLE_DEBUG_INFO' => 'NO',
  'SWIFT_COMPILATION_MODE' => 'wholemodule',
  'SWIFT_OPTIMIZATION_LEVEL' => '-O',
  'VALIDATE_PRODUCT' => 'YES',
}

proj.build_configurations.each do |cfg|
  cfg.build_settings.merge!(common_settings)
  cfg.build_settings.merge!(cfg.name == 'Debug' ? debug_only : release_only)
end

# ---------------------------------------------------------------------------
# File references for external frameworks resolved via the workspace
# ---------------------------------------------------------------------------
frameworks_group = proj.frameworks_group
loopkit_ref = frameworks_group.new_reference('LoopKit.framework')
loopkit_ref.source_tree = 'BUILT_PRODUCTS_DIR'
loopkit_ref.last_known_file_type = 'wrapper.framework'
loopkit_ref.include_in_index = '0'

loopkitui_ref = frameworks_group.new_reference('LoopKitUI.framework')
loopkitui_ref.source_tree = 'BUILT_PRODUCTS_DIR'
loopkitui_ref.last_known_file_type = 'wrapper.framework'
loopkitui_ref.include_in_index = '0'

xctest_ref = frameworks_group.new_reference('XCTest.framework')
xctest_ref.source_tree = 'DEVELOPER_DIR'
xctest_ref.path = 'Platforms/iPhoneOS.platform/Developer/Library/Frameworks/XCTest.framework'
xctest_ref.last_known_file_type = 'wrapper.framework'

# ---------------------------------------------------------------------------
# Helper: add a framework target with source files
# ---------------------------------------------------------------------------
def add_framework_target(proj, name, sources_dir, settings_overrides, linked_refs)
  target = proj.new_target(:framework, name, :ios, '17.0')
  target.build_configurations.each do |cfg|
    cfg.build_settings.merge!({
      'PRODUCT_NAME' => '$(TARGET_NAME:c99extidentifier)',
      'PRODUCT_BUNDLE_IDENTIFIER' => "org.loopkit.#{name}",
      'DEFINES_MODULE' => 'YES',
      'DYLIB_INSTALL_NAME_BASE' => '@rpath',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
      'TARGETED_DEVICE_FAMILY' => '1',
      'SKIP_INSTALL' => 'YES',
      'INFOPLIST_KEY_NSHumanReadableCopyright' => 'Copyright © 2026 LoopKit Authors. All rights reserved.',
      'CURRENT_PROJECT_VERSION' => '1',
      'MARKETING_VERSION' => '1.0',
      'GENERATE_INFOPLIST_FILE' => 'YES',
    })
    cfg.build_settings.merge!(settings_overrides) if settings_overrides
  end

  group = proj.new_group(name, sources_dir)
  Dir.glob(File.join(File.expand_path(sources_dir), '**', '*.swift')).sort.each do |path|
    rel = path.sub(File.expand_path(sources_dir) + '/', '')
    sub = rel.split('/')[0..-2]
    parent = group
    sub.each do |segment|
      existing = parent.groups.find { |g| g.name == segment }
      parent = existing || parent.new_group(segment, segment)
    end
    file_ref = parent.new_reference(File.basename(path))
    target.add_file_references([file_ref])
  end

  linked_refs.each { |ref| target.frameworks_build_phase.add_file_reference(ref) }
  target
end

# ---------------------------------------------------------------------------
# Target: LibreLoop (core framework)
# ---------------------------------------------------------------------------
libreloop = add_framework_target(proj, 'LibreLoop', 'LibreLoop', nil, [loopkit_ref])

libreloop_product_ref = libreloop.product_reference

# ---------------------------------------------------------------------------
# SwiftPM dependency: LibreCRKit (reverse-engineered Libre 3 NFC/BLE stack)
# Pin to a commit SHA since the upstream has no tags yet. Bump as needed.
# ---------------------------------------------------------------------------
librecrkit_pkg = proj.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
librecrkit_pkg.repositoryURL = 'https://github.com/airedev326/LibreCRKit.git'
librecrkit_pkg.requirement = {
  'kind' => 'revision',
  'revision' => 'd58ffdc3a7810e34ee85ddec702a92f83811bcf7',
}
proj.root_object.package_references << librecrkit_pkg

librecrkit_product = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
librecrkit_product.package = librecrkit_pkg
librecrkit_product.product_name = 'LibreCRKit'

# Link LibreCRKit into LibreLoop's binary (static linkage; framework stays
# self-contained for the plugin).
libreloop.package_product_dependencies << librecrkit_product
librecrkit_build_file = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
librecrkit_build_file.product_ref = librecrkit_product
libreloop.frameworks_build_phase.files << librecrkit_build_file

# ---------------------------------------------------------------------------
# Target: LibreLoopUI (UI framework — depends on LibreLoop, LoopKitUI)
# ---------------------------------------------------------------------------
libreloop_ui = add_framework_target(proj, 'LibreLoopUI', 'LibreLoopUI', nil, [libreloop_product_ref, loopkit_ref, loopkitui_ref])
libreloop_ui.add_dependency(libreloop)
libreloop_ui_product_ref = libreloop_ui.product_reference

# ---------------------------------------------------------------------------
# Target: LibreLoopPlugin (.loopplugin bundle)
# ---------------------------------------------------------------------------
plugin_settings = {
  'WRAPPER_EXTENSION' => 'loopplugin',
  'DEFINES_MODULE' => 'NO',
  'INFOPLIST_FILE' => 'LibreLoopPlugin/Info.plist',
  'GENERATE_INFOPLIST_FILE' => 'NO',
}
plugin = add_framework_target(proj, 'LibreLoopPlugin', 'LibreLoopPlugin', plugin_settings,
                               [libreloop_product_ref, libreloop_ui_product_ref, loopkit_ref, loopkitui_ref])
plugin.add_dependency(libreloop)
plugin.add_dependency(libreloop_ui)

# copy-plugins.sh expects the plugin bundle's own Frameworks/ subdir to contain
# the dependent frameworks; it copies them out into Loop.app/Frameworks at install
# time. Without this Embed phase, dyld can't resolve @rpath/LibreLoop.framework
# when Loop calls Bundle.loadAndReturnError().
embed = plugin.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10' # Frameworks
[libreloop_product_ref, libreloop_ui_product_ref].each do |fw_ref|
  bf = embed.add_file_reference(fw_ref)
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

plugin_group = proj.main_group.find_subpath('LibreLoopPlugin', false)
if plugin_group
  info_ref = plugin_group.new_reference('Info.plist')
  info_ref.last_known_file_type = 'text.plist.xml'
end

# ---------------------------------------------------------------------------
# Target: LibreLoopTests (XCTest bundle for LibreLoop framework)
# ---------------------------------------------------------------------------
tests = proj.new_target(:unit_test_bundle, 'LibreLoopTests', :ios, '17.0')
tests.build_configurations.each do |cfg|
  cfg.build_settings.merge!({
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'org.loopkit.LibreLoopTests',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
  })
end

tests_group = proj.new_group('LibreLoopTests', 'LibreLoopTests')
Dir.glob(File.join(REPO_ROOT, 'LibreLoopTests', '*.swift')).sort.each do |path|
  ref = tests_group.new_reference(File.basename(path))
  tests.add_file_references([ref])
end
tests.add_dependency(libreloop)
tests.frameworks_build_phase.add_file_reference(libreloop_product_ref)

# ---------------------------------------------------------------------------
# Top-level Products group is auto-managed; save and finish
# ---------------------------------------------------------------------------
# Ensure LICENSE and README appear in the project navigator
['LICENSE', 'README.md'].each do |fname|
  path = File.join(REPO_ROOT, fname)
  next unless File.exist?(path)
  proj.main_group.new_reference(fname) unless proj.main_group.children.any? { |c| c.respond_to?(:path) && c.path == fname }
end

proj.save
puts "Wrote #{PROJECT_PATH}"
