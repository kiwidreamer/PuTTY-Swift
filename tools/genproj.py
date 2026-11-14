#!/usr/bin/env python3
"""Generate PuTTY.xcodeproj/project.pbxproj for the Swift macOS app.

Scans PuTTYSwift/PuTTY for .swift and .c sources, lays out groups mirroring
the folders, and emits a single-target application project.  Deterministic
object IDs (md5-derived) keep regenerations stable.
"""
import os, sys, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # PuTTYSwift
SRC = os.path.join(ROOT, "PuTTY")
PROJ = os.path.join(ROOT, "PuTTY.xcodeproj")

def oid(key):
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()

# Collect source files.
swift_files = []
c_files = []
headers = []
resources = []
for dirpath, dirnames, filenames in os.walk(SRC):
    dirnames[:] = [d for d in dirnames if not d.endswith(".xcassets")]
    for f in sorted(filenames):
        rel = os.path.relpath(os.path.join(dirpath, f), SRC)
        if f.endswith(".swift"):
            swift_files.append(rel)
        elif f.endswith(".c"):
            c_files.append(rel)
        elif f.endswith(".h"):
            headers.append(rel)

resources = ["Assets.xcassets"] if os.path.isdir(os.path.join(SRC, "Assets.xcassets")) else []
all_files = swift_files + c_files + headers + resources + ["Info.plist"]

# IDs
objs = []
def emit(s): objs.append(s)

fileref = {}      # rel -> id
buildfile = {}    # rel -> id
for rel in all_files + ["PuTTY.app"]:
    fileref[rel] = oid("fileref:" + rel)
for rel in swift_files + c_files + resources:
    buildfile[rel] = oid("buildfile:" + rel)

PRODUCT = fileref["PuTTY.app"]
SOURCES_PHASE = oid("phase:sources")
FRAMEWORKS_PHASE = oid("phase:frameworks")
RESOURCES_PHASE = oid("phase:resources")
TARGET = oid("target:PuTTY")
PROJECT = oid("project")
MAINGROUP = oid("group:main")
PRODUCTSGROUP = oid("group:products")
TARGET_CFG_LIST = oid("cfglist:target")
PROJ_CFG_LIST = oid("cfglist:project")
TARGET_DEBUG = oid("cfg:target:debug")
TARGET_RELEASE = oid("cfg:target:release")
PROJ_DEBUG = oid("cfg:proj:debug")
PROJ_RELEASE = oid("cfg:proj:release")

def ftype(rel):
    if rel.endswith(".swift"): return "sourcecode.swift"
    if rel.endswith(".c"): return "sourcecode.c.c"
    if rel.endswith(".h"): return "sourcecode.c.h"
    if rel.endswith(".plist"): return "text.plist.xml"
    if rel.endswith(".xcassets"): return "folder.assetcatalog"
    return "text"

lines = []
lines.append("// !$*UTF8*$!")
lines.append("{")
lines.append("\tarchiveVersion = 1;")
lines.append("\tclasses = {};")
lines.append("\tobjectVersion = 56;")
lines.append("\tobjects = {")

# PBXBuildFile
lines.append("")
lines.append("/* Begin PBXBuildFile section */")
for rel in swift_files + c_files:
    lines.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                 % (buildfile[rel], os.path.basename(rel), fileref[rel], os.path.basename(rel)))
for rel in resources:
    lines.append("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                 % (buildfile[rel], rel, fileref[rel], rel))
lines.append("/* End PBXBuildFile section */")

# PBXFileReference
lines.append("")
lines.append("/* Begin PBXFileReference section */")
lines.append('\t\t%s /* PuTTY.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PuTTY.app; sourceTree = BUILT_PRODUCTS_DIR; };' % PRODUCT)
for rel in all_files:
    name = os.path.basename(rel)
    lines.append('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = "%s"; sourceTree = "<group>"; };'
                 % (fileref[rel], name, ftype(rel), name))
lines.append("/* End PBXFileReference section */")

# Build a group tree that mirrors folders.
# Map dir -> list of child dirs and child files (rel paths).
from collections import defaultdict
dir_children_dirs = defaultdict(list)
dir_children_files = defaultdict(list)
all_dirs = set([""])
for rel in all_files:
    d = os.path.dirname(rel)
    parts = d.split("/") if d else []
    accum = ""
    prev = ""
    for p in parts:
        accum = (accum + "/" + p) if accum else p
        if accum not in all_dirs:
            all_dirs.add(accum)
            dir_children_dirs[prev].append(accum)
        prev = accum
    dir_children_files[d].append(rel)

def group_id(d): return oid("group:dir:" + d) if d else MAINGROUP

lines.append("")
lines.append("/* Begin PBXGroup section */")
# main group
def emit_group(d):
    gid = group_id(d)
    name = os.path.basename(d) if d else None
    lines.append("\t\t%s = {" % gid)
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for cd in sorted(set(dir_children_dirs[d])):
        lines.append("\t\t\t\t%s /* %s */," % (group_id(cd), os.path.basename(cd)))
    for rel in sorted(dir_children_files[d]):
        lines.append("\t\t\t\t%s /* %s */," % (fileref[rel], os.path.basename(rel)))
    if d == "":
        lines.append("\t\t\t\t%s /* Products */," % PRODUCTSGROUP)
    lines.append("\t\t\t);")
    if name:
        lines.append('\t\t\tpath = "%s";' % name)
    else:
        # The root group lives in the PuTTY source folder.
        lines.append("\t\t\tpath = PuTTY;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

# emit all dir groups
emit_group("")
for d in sorted(all_dirs):
    if d == "": continue
    emit_group(d)
# products group
lines.append("\t\t%s /* Products */ = {" % PRODUCTSGROUP)
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
lines.append("\t\t\t\t%s /* PuTTY.app */," % PRODUCT)
lines.append("\t\t\t);")
lines.append("\t\t\tname = Products;")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")
lines.append("/* End PBXGroup section */")

# PBXNativeTarget
lines.append("")
lines.append("/* Begin PBXNativeTarget section */")
lines.append("\t\t%s /* PuTTY */ = {" % TARGET)
lines.append("\t\t\tisa = PBXNativeTarget;")
lines.append("\t\t\tbuildConfigurationList = %s;" % TARGET_CFG_LIST)
lines.append("\t\t\tbuildPhases = (")
lines.append("\t\t\t\t%s /* Sources */," % SOURCES_PHASE)
lines.append("\t\t\t\t%s /* Frameworks */," % FRAMEWORKS_PHASE)
lines.append("\t\t\t\t%s /* Resources */," % RESOURCES_PHASE)
lines.append("\t\t\t);")
lines.append("\t\t\tbuildRules = ();")
lines.append("\t\t\tdependencies = ();")
lines.append("\t\t\tname = PuTTY;")
lines.append("\t\t\tproductName = PuTTY;")
lines.append("\t\t\tproductReference = %s /* PuTTY.app */;" % PRODUCT)
lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
lines.append("\t\t};")
lines.append("/* End PBXNativeTarget section */")

# PBXProject
lines.append("")
lines.append("/* Begin PBXProject section */")
lines.append("\t\t%s /* Project object */ = {" % PROJECT)
lines.append("\t\t\tisa = PBXProject;")
lines.append("\t\t\tattributes = {")
lines.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
lines.append("\t\t\t\tLastUpgradeCheck = 1500;")
lines.append("\t\t\t\tTargetAttributes = { %s = { CreatedOnToolsVersion = 15.0; }; };" % TARGET)
lines.append("\t\t\t};")
lines.append("\t\t\tbuildConfigurationList = %s;" % PROJ_CFG_LIST)
lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
lines.append("\t\t\tdevelopmentRegion = en;")
lines.append("\t\t\thasScannedForEncodings = 0;")
lines.append("\t\t\tknownRegions = ( en, Base );")
lines.append("\t\t\tmainGroup = %s;" % MAINGROUP)
lines.append("\t\t\tproductRefGroup = %s /* Products */;" % PRODUCTSGROUP)
lines.append("\t\t\tprojectDirPath = \"\";")
lines.append("\t\t\tprojectRoot = \"\";")
lines.append("\t\t\ttargets = ( %s /* PuTTY */ );" % TARGET)
lines.append("\t\t};")
lines.append("/* End PBXProject section */")

# Phases
lines.append("")
lines.append("/* Begin PBXSourcesBuildPhase section */")
lines.append("\t\t%s /* Sources */ = {" % SOURCES_PHASE)
lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for rel in swift_files + c_files:
    lines.append("\t\t\t\t%s /* %s in Sources */," % (buildfile[rel], os.path.basename(rel)))
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXSourcesBuildPhase section */")

lines.append("")
lines.append("/* Begin PBXFrameworksBuildPhase section */")
lines.append("\t\t%s /* Frameworks */ = {" % FRAMEWORKS_PHASE)
lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = ();")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXFrameworksBuildPhase section */")

lines.append("")
lines.append("/* Begin PBXResourcesBuildPhase section */")
lines.append("\t\t%s /* Resources */ = {" % RESOURCES_PHASE)
lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for rel in resources:
    lines.append("\t\t\t\t%s /* %s in Resources */," % (buildfile[rel], rel))
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXResourcesBuildPhase section */")

# Build configurations
def proj_settings(debug):
    s = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "MACOSX_DEPLOYMENT_TARGET": "12.0",
        "SDKROOT": "macosx",
        "SWIFT_VERSION": "5.0",
    }
    if debug:
        s["GCC_OPTIMIZATION_LEVEL"] = "0"
        s["ONLY_ACTIVE_ARCH"] = "YES"
        s["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
        s["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        s["DEBUG_INFORMATION_FORMAT"] = "dwarf"
    else:
        s["SWIFT_OPTIMIZATION_LEVEL"] = "-O"
        s["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
        s["ENABLE_NS_ASSERTIONS"] = "NO"
    return s

def target_settings(debug):
    return {
        "PRODUCT_NAME": "PuTTY",
        "PRODUCT_BUNDLE_IDENTIFIER": "org.greenend.putty.swift",
        "INFOPLIST_FILE": "PuTTY/Info.plist",
        "SWIFT_OBJC_BRIDGING_HEADER": "PuTTY/PuTTY-Bridging-Header.h",
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_IDENTITY": "-",
        "COMBINE_HIDPI_IMAGES": "YES",
        "LD_RUNPATH_SEARCH_PATHS": "( \"$(inherited)\", \"@executable_path/../Frameworks\" )",
        "MACOSX_DEPLOYMENT_TARGET": "12.0",
        "GENERATE_INFOPLIST_FILE": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    }

def emit_cfg(cfg_id, name, settings):
    lines.append("\t\t%s /* %s */ = {" % (cfg_id, name))
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    for k in sorted(settings.keys()):
        v = settings[k]
        if v.startswith("("):
            lines.append("\t\t\t\t%s = %s;" % (k, v))        # array literal
        else:
            lines.append('\t\t\t\t%s = "%s";' % (k, v))       # quote everything else
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = %s;" % name)
    lines.append("\t\t};")

lines.append("")
lines.append("/* Begin XCBuildConfiguration section */")
emit_cfg(PROJ_DEBUG, "Debug", proj_settings(True))
emit_cfg(PROJ_RELEASE, "Release", proj_settings(False))
emit_cfg(TARGET_DEBUG, "Debug", target_settings(True))
emit_cfg(TARGET_RELEASE, "Release", target_settings(False))
lines.append("/* End XCBuildConfiguration section */")

lines.append("")
lines.append("/* Begin XCConfigurationList section */")
lines.append("\t\t%s /* Build configuration list for PBXProject */ = {" % PROJ_CFG_LIST)
lines.append("\t\t\tisa = XCConfigurationList;")
lines.append("\t\t\tbuildConfigurations = ( %s /* Debug */, %s /* Release */ );" % (PROJ_DEBUG, PROJ_RELEASE))
lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
lines.append("\t\t\tdefaultConfigurationName = Release;")
lines.append("\t\t};")
lines.append("\t\t%s /* Build configuration list for PBXNativeTarget */ = {" % TARGET_CFG_LIST)
lines.append("\t\t\tisa = XCConfigurationList;")
lines.append("\t\t\tbuildConfigurations = ( %s /* Debug */, %s /* Release */ );" % (TARGET_DEBUG, TARGET_RELEASE))
lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
lines.append("\t\t\tdefaultConfigurationName = Release;")
lines.append("\t\t};")
lines.append("/* End XCConfigurationList section */")

lines.append("\t};")
lines.append("\trootObject = %s /* Project object */;" % PROJECT)
lines.append("}")

os.makedirs(PROJ, exist_ok=True)
with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
    f.write("\n".join(lines) + "\n")
print("Wrote", os.path.join(PROJ, "project.pbxproj"))
print("swift:", len(swift_files), "c:", len(c_files))
