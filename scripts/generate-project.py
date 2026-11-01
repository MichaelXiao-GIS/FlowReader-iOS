#!/usr/bin/env python3
"""Generate the dependency-free Xcode project; no third-party project generator needed."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, text):
    objects[ident(name)] = text
    return ident(name)
def arr(items): return '(' + ', '.join(items) + ',)'
def quote(s): return '"' + s.replace('"', '\\"') + '"'
def settings(d): return '{' + ''.join(f'{k} = {v};' for k,v in d.items()) + '}'

products = []
targets = []
groups = []
for name, product_type, ext in [('FlowReader','application','app'),('FlowReaderTests','bundle.unit-test','xctest'),('FlowReaderUITests','bundle.ui-testing','xctest')]:
    product = add(name+'product',f'{{isa = PBXFileReference; explicitFileType = {quote("wrapper.application" if ext == "app" else "wrapper.cfbundle")}; path = {name}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;}}')
    products.append(product)
    if name == 'FlowReader':
        exception = add('exceptions','{isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Info.plist,); target = '+ident(name+'target')+';}')
        exceptions = f'exceptions = ({exception},);'
    else: exceptions = ''
    group = add(name+'group',f'{{isa = PBXFileSystemSynchronizedRootGroup; {exceptions} path = {name}; sourceTree = "<group>";}}')
    groups.append(group)
    phases = [add(name+phase,f'{{isa = PBX{phase}BuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;}}') for phase in ['Sources','Frameworks','Resources']]
    cfgs=[]
    for config in ['Debug','Release']:
        opts={'PRODUCT_NAME':'"$(TARGET_NAME)"','PRODUCT_BUNDLE_IDENTIFIER':f'com.michaelxiao.flowreader{("."+name.lower()) if name != "FlowReader" else ""}','SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'27.0','TARGETED_DEVICE_FAMILY':'"1,2"','CODE_SIGN_STYLE':'Automatic','GENERATE_INFOPLIST_FILE':'YES','SWIFT_EMIT_LOC_STRINGS':'YES','MARKETING_VERSION':'1.6.0','CURRENT_PROJECT_VERSION':'11','SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"'}
        if name=='FlowReader': opts.update({'GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'FlowReader/Info.plist','ASSETCATALOG_COMPILER_APPICON_NAME':'FlowIcon','LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/Frameworks"','SUPPORTS_MACCATALYST':'NO','SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD':'NO'})
        elif name=='FlowReaderTests': opts.update({'BUNDLE_LOADER':'"$(TEST_HOST)"','TEST_HOST':'"$(BUILT_PRODUCTS_DIR)/FlowReader.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/FlowReader"'})
        else: opts['TEST_TARGET_NAME']='FlowReader'
        cfgs.append(add(name+config,f'{{isa = XCBuildConfiguration; buildSettings = {settings(opts)}; name = {config};}}'))
    cfglist = add(name+'configs',f'{{isa = XCConfigurationList; buildConfigurations = {arr(cfgs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}}')
    deps=[]
    if name!='FlowReader':
        proxy=add(name+'proxy','{isa = PBXContainerItemProxy; containerPortal = '+ident('project')+'; proxyType = 1; remoteGlobalIDString = '+ident('FlowReadertarget')+'; remoteInfo = FlowReader;}')
        deps.append(add(name+'dep','{isa = PBXTargetDependency; target = '+ident('FlowReadertarget')+'; targetProxy = '+proxy+';}'))
    targets.append(add(name+'target',f'{{isa = PBXNativeTarget; buildConfigurationList = {cfglist}; buildPhases = {arr(phases)}; buildRules = (); dependencies = {arr(deps) if deps else "()"}; fileSystemSynchronizedGroups = ({group},); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{product_type}";}}'))

productgroup=add('products','{isa = PBXGroup; children = '+arr(products)+'; name = Products; sourceTree = "<group>";}')
maingroup=add('main','{isa = PBXGroup; children = '+arr(groups+[productgroup])+'; sourceTree = "<group>";}')
configs=[]
for config in ['Debug','Release']:
    opts={'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SDKROOT':'iphoneos','SWIFT_OPTIMIZATION_LEVEL':quote('-Onone' if config=='Debug' else '-O'),'ENABLE_TESTABILITY':'YES' if config=='Debug' else 'NO','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else '"dwarf-with-dsym"','GCC_PREPROCESSOR_DEFINITIONS':'"DEBUG=1 $(inherited)"' if config=='Debug' else '"$(inherited)"','SWIFT_ACTIVE_COMPILATION_CONDITIONS':quote('DEBUG $(inherited)' if config=='Debug' else '$(inherited)')}
    configs.append(add(config,f'{{isa = XCBuildConfiguration; buildSettings = {settings(opts)}; name = {config};}}'))
cfg=add('configs',f'{{isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}}')
add('project',f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2710;}}; buildConfigurationList = {cfg}; compatibilityVersion = "Xcode 16.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base,); mainGroup = {maingroup}; preferredProjectObjectVersion = 77; productRefGroup = {productgroup}; projectDirPath = ""; projectRoot = ""; targets = {arr(targets)};}}')
project=root/'FlowReader.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 77; objects = {\n'+ '\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+ident('project')+';}\n')
scheme=project/'xcshareddata/xcschemes'
scheme.mkdir(parents=True,exist_ok=True)
def ref(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name+"target")}" BuildableName="{name}.{"app" if name=="FlowReader" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:FlowReader.xcodeproj"/>'
(scheme/'FlowReader.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('FlowReader')}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('FlowReaderTests')}</TestableReference><TestableReference skipped="NO">{ref('FlowReaderUITests')}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('FlowReader')}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('FlowReader')}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
