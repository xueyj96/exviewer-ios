#!/usr/bin/env python3
"""Generate only the ExViewer Xcode project from this project's source inventory."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

root = Path(__file__).resolve().parent.parent
existing_teams = {}
existing_project = root / 'ExViewer.xcodeproj' / 'project.pbxproj'
if existing_project.exists():
    try:
        parsed = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(existing_project)], stderr=subprocess.PIPE))
        old_objects = parsed['objects']
        for target in old_objects.values():
            if target.get('isa') == 'PBXNativeTarget' and target.get('name') == 'ExViewer':
                for config_id in old_objects[target['buildConfigurationList']]['buildConfigurations']:
                    config = old_objects[config_id]
                    team = config['buildSettings'].get('DEVELOPMENT_TEAM')
                    if team:
                        if not re.fullmatch(r'[A-Z0-9]{10}', team):
                            raise ValueError('Unrecognized development team')
                        existing_teams[config['name']] = team
    except (subprocess.CalledProcessError, KeyError, ValueError):
        raise SystemExit('Cannot read existing signing configuration; original project preserved.')
def ident(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
objects = []
def obj(name, value): objects.append(f'{ident(name)} = {{{value}}};')
def ref(name): return ident(name)
files = sorted((root / 'App').glob('*.swift'))
for path in files:
    name = path.name
    obj('file:' + name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>";')
    obj('source:' + name, f'isa = PBXBuildFile; fileRef = {ref("file:" + name)};')
obj('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(ref('source:' + p.name) for p in files) + '); runOnlyForDeploymentPostprocessing = 0;')
obj('app-group', 'isa = PBXGroup; path = App; sourceTree = "<group>"; children = (' + ','.join(ref('file:' + p.name) for p in files) + ');')
obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = Core;')
obj('product-core', f'isa = XCSwiftPackageProductDependency; package = {ref("package")}; productName = ExViewerCore;')
obj('link-core', f'isa = PBXBuildFile; productRef = {ref("product-core")};')
obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ref("link-core")}); runOnlyForDeploymentPostprocessing = 0;')
obj('assets-file', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = App/Assets.xcassets; sourceTree = SOURCE_ROOT;')
obj('assets-build', f'isa = PBXBuildFile; fileRef = {ref("assets-file")};')
resource_files = sorted((root / 'App' / 'Resources').glob('*'))
for resource in resource_files:
    if not resource.is_file():
        continue
    obj('resource-file:' + resource.name, f'isa = PBXFileReference; path = "{resource.name}"; sourceTree = "<group>";')
    obj('resource-build:' + resource.name, f'isa = PBXBuildFile; fileRef = {ref("resource-file:" + resource.name)};')
obj('resources-group', 'isa = PBXGroup; path = App/Resources; sourceTree = SOURCE_ROOT; children = (' + ','.join(ref('resource-file:' + p.name) for p in resource_files if p.is_file()) + ');')
obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join([ref('assets-build')] + [ref('resource-build:' + p.name) for p in resource_files if p.is_file()]) + '); runOnlyForDeploymentPostprocessing = 0;')
obj('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = ExViewer.app; sourceTree = BUILT_PRODUCTS_DIR;')
ui_files = sorted((root / 'UITests').glob('*.swift'))
for ui_file in ui_files:
    obj('test-file:' + ui_file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{ui_file.name}"; sourceTree = "<group>";')
    obj('test-source:' + ui_file.name, f'isa = PBXBuildFile; fileRef = {ref("test-file:" + ui_file.name)};')
obj('test-sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(ref('test-source:' + file.name) for file in ui_files) + '); runOnlyForDeploymentPostprocessing = 0;')
obj('test-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('test-group', 'isa = PBXGroup; path = UITests; sourceTree = "<group>"; children = (' + ','.join(ref('test-file:' + file.name) for file in ui_files) + ');')
obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ExViewerUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; name = Products; children = ({ref("app-product")},{ref("test-product")},{ref("unit-product")}); sourceTree = "<group>";')
obj('root-group', f'isa = PBXGroup; children = ({ref("app-group")},{ref("test-group")},{ref("unit-group")},{ref("assets-file")},{ref("resources-group")},{ref("products")}); sourceTree = "<group>";')
obj('target', f'isa = PBXNativeTarget; name = ExViewer; productName = ExViewer; productType = "com.apple.product-type.application"; buildConfigurationList = {ref("target-config")}; buildPhases = ({ref("sources")},{ref("frameworks")},{ref("resources")}); buildRules = (); dependencies = (); packageProductDependencies = ({ref("product-core")}); productReference = {ref("app-product")};')
obj('test-proxy', f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("target")}; remoteInfo = ExViewer;')
obj('test-dependency', f'isa = PBXTargetDependency; target = {ref("target")}; targetProxy = {ref("test-proxy")};')
obj('test-target', f'isa = PBXNativeTarget; name = ExViewerUITests; productName = ExViewerUITests; productType = "com.apple.product-type.bundle.ui-testing"; buildConfigurationList = {ref("test-config")}; buildPhases = ({ref("test-sources")},{ref("test-frameworks")}); buildRules = (); dependencies = ({ref("test-dependency")}); productReference = {ref("test-product")};')
unit_files = sorted((root / 'UnitTests').glob('*.swift'))
for unit_file in unit_files:
    obj('unit-file:' + unit_file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{unit_file.name}"; sourceTree = "<group>";')
    obj('unit-source:' + unit_file.name, f'isa = PBXBuildFile; fileRef = {ref("unit-file:" + unit_file.name)};')
obj('unit-sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(ref('unit-source:' + file.name) for file in unit_files) + '); runOnlyForDeploymentPostprocessing = 0;')
obj('unit-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('unit-group', 'isa = PBXGroup; path = UnitTests; sourceTree = "<group>"; children = (' + ','.join(ref('unit-file:' + file.name) for file in unit_files) + ');')
obj('unit-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ExViewerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('unit-target', f'isa = PBXNativeTarget; name = ExViewerTests; productName = ExViewerTests; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = {ref("unit-config")}; buildPhases = ({ref("unit-sources")},{ref("unit-frameworks")}); buildRules = (); dependencies = ({ref("test-dependency")}); productReference = {ref("unit-product")};')
for config in ['Debug', 'Release']:
    debug = config == 'Debug'
    shared = 'CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0;'
    obj('project-' + config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{{shared}}};')
    settings = '''PRODUCT_BUNDLE_IDENTIFIER = com.xueyj.exviewer; PRODUCT_NAME = "$(TARGET_NAME)";
    GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = ExViewer;
    INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.books";
    INFOPLIST_KEY_UILaunchScreen_Generation = YES;
    INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
    INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
    INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
    INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
    CURRENT_PROJECT_VERSION = 22; MARKETING_VERSION = 0.1.0;
    TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic;
    "CODE_SIGN_IDENTITY[sdk=iphonesimulator*]" = "-";
    "CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]" = YES;
    ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
    SWIFT_EMIT_LOC_STRINGS = YES; ENABLE_USER_SCRIPT_SANDBOXING = YES;
    LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
    '''
    settings += 'SWIFT_OPTIMIZATION_LEVEL = -Onone; ENABLE_TESTABILITY = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";' if debug else 'SWIFT_OPTIMIZATION_LEVEL = -O;'
    if config in existing_teams:
        settings += f'DEVELOPMENT_TEAM = {existing_teams[config]};'
    obj('target-' + config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{{settings}}};')
    obj('test-' + config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{PRODUCT_BUNDLE_IDENTIFIER = com.xueyj.exviewer.uitests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = iphonesimulator; TEST_TARGET_NAME = ExViewer; CODE_SIGN_STYLE = Automatic; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0;}};')
    obj('unit-' + config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{PRODUCT_BUNDLE_IDENTIFIER = com.xueyj.exviewer.tests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = iphonesimulator; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ExViewer.app/ExViewer"; BUNDLE_LOADER = "$(TEST_HOST)"; CODE_SIGN_STYLE = Automatic; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0;}};')
for scope in ['project', 'target', 'test', 'unit']:
    obj(scope + '-config', f'isa = XCConfigurationList; buildConfigurations = ({ref(scope + "-Debug")},{ref(scope + "-Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700;}}; buildConfigurationList = {ref("project-config")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; knownRegions = (en,Base,"zh-Hans"); mainGroup = {ref("root-group")}; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; packageReferences = ({ref("package")}); targets = ({ref("target")},{ref("test-target")},{ref("unit-target")});')
project = root / 'ExViewer.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ref("project")};}}\n')
schemes = project / 'xcshareddata' / 'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'ExViewer.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('target')}" BuildableName="ExViewer.app" BlueprintName="ExViewer" ReferencedContainer="container:ExViewer.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><CommandLineArguments><CommandLineArgument argument="--qa" isEnabled="YES"/></CommandLineArguments><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('unit-target')}" BuildableName="ExViewerTests.xctest" BlueprintName="ExViewerTests" ReferencedContainer="container:ExViewer.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('test-target')}" BuildableName="ExViewerUITests.xctest" BlueprintName="ExViewerUITests" ReferencedContainer="container:ExViewer.xcodeproj"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('target')}" BuildableName="ExViewer.app" BlueprintName="ExViewer" ReferencedContainer="container:ExViewer.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('target')}" BuildableName="ExViewer.app" BlueprintName="ExViewer" ReferencedContainer="container:ExViewer.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated', project)
