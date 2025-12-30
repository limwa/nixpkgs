#!/usr/bin/env nix-shell
#!nix-shell -I nixpkgs=../../../.. -i python3 -p python3 python3.pkgs.requests python3.pkgs.xmltodict

### After making change:
### - Format the script by running: nix run nixpkgs#black pkgs/development/mobile/androidenv/update.py
### - Run the unit test by running: python3 -m unittest pkgs/development/mobile/androidenv/update.py
### - Run the type checking by running: nix run nixpkgs#mypy pkgs/development/mobile/androidenv/update.py

# pyright: basic

import argparse
import json
from collections import deque
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated, Generator, Hashable, Literal, NotRequired, cast, Any, TypedDict, Callable, get_args, get_origin, get_type_hints
import requests
import xml.etree.ElementTree as ET
import glob
import re
import functools
import sys

###
### Global variables
###

logger = logging.getLogger(__name__)

###
### Global constants
###

TRACE = 5
SANITIZE_URL_REGEX = re.compile(r"\W*(?!\.\w+$)\W")
SANITIZE_ATTR_NAME_REGEX = re.compile(r"[-:]")

VERBOSITY_ATTR_STATISTICS = 1
VERBOSITY_DEBUG = 2
VERBOSITY_TRACE = 3

##
## These are the default repositories that will be fetched if the user does not provide any.
## Fetching these repositories can be disabled by passing the --skip-default-repositories flag.
##
DEFAULT_REPOSITORIES = [
    "https://dl.google.com/android/repository/repository2-3.xml",
    "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/android-tv/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/android-wear/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/android-wear-cn/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/android-automotive/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml",
    "https://dl.google.com/android/repository/addon2-3.xml",
]

## These are attributes which will always be forced to be a list in the resulting JSON.
##
## This is important because xmltodict will not parse the XML attribute as a list if
## it only has a single child element, but in Nix we want to have it as consistent as
## possible to reduce the complexity of the code.
## 
##  To update this list, run the following command and follow the instructions:
## ./update.py --print-force-list-heuristic [...]
## 
XML_FORCE_LIST = (
    "archive",
    "channel",
    "dependency",
    "library",
    "license",
    "remotePackage",
    "tag",
)

###
### Generic functions
###

@dataclass
class Trace:
    visible: bool
    
def traced(hide_return: bool = False):
    
    def decorator[**P, R](func: Callable[P, R]) -> Callable[P, R]:
        type_hints = get_type_hints(func, include_extras=True)
        
        hidden_args = set[int]()
        hidden_kwargs = set[str]()
        
        for i, (key, hint) in enumerate(type_hints.items()):
            if key == "return" or get_origin(hint) is not Annotated:
                continue
                
            settings = Trace(visible=True)
            
            _, *hint_args = get_args(hint)
            for hint_arg in hint_args:
                if isinstance(hint_arg, Trace):
                    settings.visible = hint_arg.visible
            
            if not settings.visible:
                hidden_args.add(i)
                hidden_kwargs.add(key)
        
        @functools.wraps(func)
        def wrapper(*args: P.args, **kwargs: P.kwargs):
            logger.log(
                TRACE,
                "%(func_name)s:CALL *%(args)s **%(kwargs)s",
                {
                    "func_name": str(func.__name__),
                    "args": str([arg if i not in hidden_args else f"<hidden {type(arg)}" for i, arg in enumerate(args)]),
                    "kwargs": str({ key: kwarg if key not in hidden_kwargs else f"<hidden {type(kwarg)}>" for key, kwarg in kwargs.items() })
                }
            )
            
            res = func(*args, **kwargs)
            logger.log(TRACE, "%(func_name)s:RETURN %(res)s", { "func_name": str(func.__name__), "res": str(res) if not hide_return else f"<hidden {type(res)}>" })
            return res
    
        return wrapper
        
    return decorator


@traced()
def sanitize_url(url: str) -> str:
    """
    Sanitizes the given URL by replacing all non-word characters with "-".
    If the URL ends with a file extension, such as ".xml", the "." is not replaced.
    """
    
    return SANITIZE_URL_REGEX.sub("-", url)
    
@traced()
def write_response_to_file(response: Annotated[requests.Response, Trace(visible=False)], dest_file: Path) -> None:
    """
    Writes the response body to the given file.
    """
    
    response.raise_for_status()
    with open(dest_file, "wb") as f:
        for chunk in response.iter_content(chunk_size=8192):
            if chunk:
                _ = f.write(chunk)
                
type KeyHierarchy = list[str]
type TypeHierarchy = list[type]
type ForeachWithHierarchyResult[T] = tuple[T, KeyHierarchy, TypeHierarchy]

@traced()
def foreach_with_hierarchy(
    root: Annotated[dict[str, Any], Trace(visible=False)],
) -> Generator[ForeachWithHierarchyResult[Any], None, None]:
    """
    Recursively explore all values in the given root.
    """
    
    dicts_queue = deque[
        ForeachWithHierarchyResult[dict[str, Any]]
    ]([ (root, [], [dict]), ])
    
    while len(dicts_queue) > 0:
        (curr_dict, key_hierarchy, type_hierarchy) = dicts_queue.popleft()
        yield (curr_dict, key_hierarchy, type_hierarchy)

        for key, value in curr_dict.items():
            next_key_hierarchy = key_hierarchy + [key]
            next_type_hierarchy = type_hierarchy + [type(value)]
            
            yield (value, next_key_hierarchy, next_type_hierarchy)
            
            if isinstance(value, list):    
                for item in value:
                    if isinstance(item, dict):
                        dicts_queue.append((item, next_key_hierarchy, next_type_hierarchy + [dict]))
                    else:
                        # Here, we don't need to check for lists, because xmltodict
                        # doesn't create nested lists.
                        raise ValueError(f"Unexpected value type: {type(item)}")
                        
            elif isinstance(value, dict):
                dicts_queue.append((value, next_key_hierarchy, next_type_hierarchy))

###
### Fetching repositories and converting them to JSON
###

@traced()
def fetch_repositories(base_dir: Path, repositories: list[str]) -> list[Path]:
    """
    Fetches the repositories from the given URLs and stores them in the given directory,
    under the "xml" directory.
    """
    
    repositories_dir = base_dir / "xml"
    repositories_dir.mkdir(parents=True, exist_ok=True)
        
    paths = cast(list[Path], [])
    for url in repositories:
        path = fetch_repository(repositories_dir, url)
        paths.append(path)
        
    return paths

@traced()
def fetch_repository(xml_dir: Path, url: str) -> Path:
    dest_file = xml_dir / sanitize_url(url)
    
    logger.info("Fetching repository: %s", url)
    
    with requests.get(url, stream=True, timeout=10) as response:
        write_response_to_file(response, dest_file)
        
    return dest_file
    
@traced(hide_return=True)
def convert_repository_to_dict(path: Path, use_force_list: bool = True) -> dict[str, Any]:
    repo = xmltodict.parse(
        path.read_text(encoding="utf-8"),
        # If one of these is a list in at least one of the files, then it
        # should be a list in all of the files, for consistency and to facilitate
        # the manipulation of the data.
        force_list=XML_FORCE_LIST if use_force_list else (),
        # We use attr_prefix="attr_" because the default ("@") is not a valid
        # character for Python identifiers.
        attr_prefix="attr_",
        # We use a postprocessor to replace all "-" and ":" with "_" in the attribute names.
        # Once again, these characters are not valid for Python identifiers.
        postprocessor=lambda _, name, value: (SANITIZE_ATTR_NAME_REGEX.sub("_", name), value),
    )
    
    return repo

type ForceListHeuristicReason = Literal["single-child", "is-list"]
type ForceListHeuristicResult = tuple[str, ForceListHeuristicReason]

@traced()
def find_force_list_elements(repo: Annotated[dict[str, Any], Trace(visible=False)]) -> set[ForceListHeuristicResult]:
    """
    An element needs to be included in the force list if:
        - at least one of its instances is a list
        - there's one instance where its parent is a dict within a dict, the instance is a dict, and the instance is the parent's only child
            - this is done to take into account elements such as "sdk -> dependencies -> dependency", when
              all artifacts only have one dependency (and thus, xmltodict parses it as an object)
          
    In this heuristic, we don't really care about returning false-positives, and instead we prefer to minimize false-negatives.
    """
    
    attrs = set[ForceListHeuristicResult]()
    
    for value, key_hierarchy, type_hierarchy in foreach_with_hierarchy(repo):
        if isinstance(value, list):
            attrs.add((key_hierarchy[-1], "is-list"))
        elif isinstance(value, dict):
            if len(type_hierarchy) < 2 or type_hierarchy[-2] is not dict:
                # We don't want to consider dicts that are not nested within another dict.
                continue
               
            if len(value) == 1:
                # At this point, we know that value is a dict within a dict, and that it
                # has a single child.
                # 
                # We need to check if the child is a dict, and if so, add it to the heuristic results.
                single_child_key = next(iter(value.keys()))
                if isinstance(value[single_child_key], dict):
                    attrs.add((single_child_key, "single-child"))
          
    return attrs
    
@traced()
def execute_force_list_heuristic(repository_paths: list[Path]) -> None:
    # First, we'll calculate all of the potential force list attributes.

    heuristic_results = set[ForceListHeuristicResult]()
    for repository_path in repository_paths:
        repo = convert_repository_to_dict(repository_path, use_force_list=False)
        heuristic_results = heuristic_results | find_force_list_elements(repo)
        
    # Then, we'll print the results.

    print("##")
    print("## Force list heuristic results")
    print("##")
    print()
    
    list_results = set(key for (key, reason) in heuristic_results if reason == "is-list")
    single_child_results = set(key for (key, reason) in heuristic_results if reason == "single-child" and key not in list_results)
    
    if len(list_results) > 0:
        print("The following elements appear as a list in at least one of the repositories:")
        print()
        
        for element in sorted(list_results):
            print (f"  - {element}")
            
        print()
        print("  [!] Recommendation: make sure all of these elements are in the force list")
        print()
        print()
    
    if len(single_child_results) > 0:
        print("The following elements appear as a single child of another element in at least one of the repositories:")
        print()
        
        for element in sorted(single_child_results):
            print (f"  - {element}")
            
        print()
        print("  [!] Recommendation: for each of these elements, check the repository XML and determine if it makes more sense for the element to be in the force list or not")
        print()
        print()
    
    if len(list_results) == 0 and len(single_child_results) == 0:
        print("The heuristic yielded no results. This could happen if no repositories were provided.")
        print()
        
    print("[!] Note #1: this heuristic does not take into account the XML_FORCE_LIST variable.")
    print("[!] Note #2: this heuristic is not perfect, and may produce false positives or false negatives.")
    print()

@dataclass
class AttrFilterCondition:
    attr_name: str
    attr_repr: str
    
    def matches(self, obj: dict[str, Any]) -> bool:
        value = obj.get(self.attr_name, None)
        return repr(value) == self.attr_repr

@dataclass
class AttrFilter:
    path: list[str]
    conditions: list[AttrFilterCondition]
    
def parse_attr_filter(filter: str) -> AttrFilter:
    attr_path, *conditions = filter.split("/")

    parsed_path = attr_path.split(".")
    
    parsed_conditions = list[AttrFilterCondition]()
    for condition in conditions:
        attr_name, attr_repr = condition.split("=")
        parsed_conditions.append(AttrFilterCondition(attr_name, attr_repr))
        
    return AttrFilter(path=parsed_path, conditions=parsed_conditions)

def execute_attr_statistics(repository_paths: list[Path], filter: str, verbose: bool = False) -> None:
    parsed_filter = parse_attr_filter(filter)
    
    matches_count = 0 
    key_stats = dict[str, int]()
    type_stats = dict[str, dict[type, int]]()
    value_stats = dict[str, dict[Hashable, int]]()
        
    for repository_path in repository_paths:
        repo = convert_repository_to_dict(repository_path)
        
        for value, key_hierarchy, _ in foreach_with_hierarchy(repo):
            if not isinstance(value, dict):
                # We avoid everything that's not a dict because it makes
                # the code simpler.
                continue
            
            # To check if we should match this value, we need to check if all elements
            # from `parsed_filter.path` appear, in order, in the key hierarchy. Furthermore,
            # the last element of the key hierarchy should be the last element of `parsed_filter.path`.
            curr_index = 0
            for attr in parsed_filter.path:
                try:
                    index = key_hierarchy.index(attr, curr_index)
                    curr_index = index + 1
                except ValueError:
                    # If the attribute is not found, we can't match this value.
                    curr_index = -1
                    break
                    
            if curr_index < len(key_hierarchy):
                # If the last element of the key hierarchy is not the last element of `attrs`,
                # we can't match this value.
                continue
            
            if not all(condition.matches(value) for condition in parsed_filter.conditions):
                continue
            
            matches_count += 1
            
            for k, v in value.items():
                key_stats.setdefault(k, 0)
                key_stats[k] += 1
                
                type_stats.setdefault(k, dict())
                type_stats[k].setdefault(type(v), 0)
                type_stats[k][type(v)] += 1
                
                value_stats.setdefault(k, dict())
                v = v if isinstance(v, Hashable) else type(v)
                value_stats[k].setdefault(v, 0)
                value_stats[k][v] += 1
    
    print("##")
    print(f"## Attribute statistics for attribute '{".".join(parsed_filter.path)}'")
    print("##")
    print()

    print(f"Found a total of {matches_count} matches.")
    print()
    
    if len(key_stats) > 0:
        print("The following statistics were collected for the names of the keys:")
        print()
        
        for k, v in key_stats.items():
            print(f"  - key \"{k}\" was present in {v / matches_count:.2%} of the matches (total {v})")
        print()
        
    if len(type_stats) > 0:
        print("The following statistics were collected for the types of the values:")
        print()
        
        for k, v in type_stats.items():
            key_matches = key_stats.get(k, 0)
            print(f"  - key \"{k}\" had the following types:")
            for t, count in v.items():
                print(f"    - type \"{t}\" in {count / key_matches:.2%} of the occurrences (total {count})")
            print()
        print()
        
    if len(value_stats) > 0:
        print("The following statistics were collected for the values of the dictionary:")
        print()
        
        for k, v in value_stats.items():
            key_matches = key_stats.get(k, 0)
            omitted_count = 0
            
            print(f"  - key \"{k}\" had the following values:")
            for v_, count in v.items():
                prevalence = count / key_matches
                
                if not verbose and len(v) > 15 and prevalence < 0.05:
                    omitted_count += 1
                    continue
                    
                print(f"    - value {repr(v_)} in {prevalence:.2%} of the occurrences (total {count})")
            
            if omitted_count > 0:
                print()
                print(f"    [!] Omitted {omitted_count} distinct values because they were used in less than 5% of the occurrences.")

            print()
            
        print()
                
### 
### Rewriting the JSON format to a format that is easier to work with
###

# These are required because #text, @id, ..., are not valid Python identifiers.
XmlText = TypedDict("XmlText", { "#text": str })

# These classes are 1-to-1 mappings of the JSON objects generated by xmltodict.
# You can use ./update.py --print-attr-statistics [...] to find information about the attributes.
# 
# Example: ./update.py --print-attr-statistics "remotePackage.complete"

# ./update.py --print-attr-statistics "license"
class LicenseDict(XmlText, TypedDict):
    attr_id: str

# ./update.py --print-attr-statistics "channel"
class ChannelDict(XmlText, TypedDict):
    attr_id: str

# ./update.py --print-attr-statistics "revision" --print-attr-statistics "min_revision"
class RevisionDict(TypedDict):
    major: str
    minor: NotRequired[str]
    micro: NotRequired[str]
    preview: NotRequired[str]

# ./update.py --print-attr-statistics "uses_license" --print-attr-statistics "channelRef"
class RefDict(TypedDict):
    attr_ref: str

# ./update.py --print-attr-statistics "dependency"
class DependencyDict(TypedDict):
    attr_path: str
    min_revision: NotRequired[RevisionDict]

# ./update.py --print-attr-statistics "dependencies"
class DependenciesDict(TypedDict):
    dependency: list[DependencyDict]

# ./update.py --print-attr-statistics "checksum"
class ChecksumDict(XmlText, TypedDict):
    attr_type: Literal["sha1"]

# ./update.py --print-attr-statistics "archive.complete"
class ArchiveSourceDict(TypedDict):
    size: str
    checksum: ChecksumDict
    url: str

# ./update.py --print-attr-statistics "archive"
class ArchiveDict(TypedDict):
    complete: ArchiveSourceDict
    host_os: NotRequired[Literal["linux", "macosx", "windows"]]
    host_arch: NotRequired[Literal["aarch64", "x64", "x86"]]

# ./update.py --print-attr-statistics "archives"
class ArchivesDict(TypedDict):
    archive: list[ArchiveDict]

# ./update.py --print-attr-statistics "remotePackage"
class RemotePackageDict[D](TypedDict):
    attr_path: str
    type_details: D
    revision: RevisionDict
    display_name: str
    uses_license: RefDict
    dependencies: DependenciesDict
    channelRef: RefDict
    archives: ArchivesDict

# ./update.py --print-attr-statistics "vendor" --print-attr-statistics "tag"
class DisplayNameDict(TypedDict):
    id: str
    display: str | None

# ./update.py --print-attr-statistics "type_details/attr_xsi_type='sys-img:sysImgDetailsType'"
class SystemImageDetails(TypedDict):
    api_level: str
    extension_level: NotRequired[str]
    base_extension: Literal["true", "false"]
    tag: list[DisplayNameDict]
    abi: Literal["arm64-v8a", "armeabi-v7a", "mips", "x86", "x86_64"]
    vendor: NotRequired[DisplayNameDict]
    codename: NotRequired[str]

# ./update.py --print-attr-statistics "library"
class LibraryDict(TypedDict):
    attr_name: str
    attr_localJarPath: str
    description: str
    
# ./update.py --print-attr-statistics "libraries"
class LibrariesDict(TypedDict):
    library: list[LibraryDict]
    
# ./update.py --print-attr-statistics "type_details/attr_xsi_type='addon:addonDetailsType'"
class AddonDetails(TypedDict):
    api_level: str
    codename: NotRequired[str]
    base_extension: Literal["true", "false"]
    vendor: DisplayNameDict
    libraries: LibrariesDict
    
# ./update.py --print-attr-statistics "type_details/attr_xsi_type='addon:extraDetailsType'"
class ExtraDetails(TypedDict):
    vendor: DisplayNameDict

# ./update.py --print-attr-statistics "layoutlib"
class LayoutLibDict(TypedDict):
    attr_api: str

# ./update.py --print-attr-statistics "type_details/attr_xsi_type='sdk:platformDetailsType'"
class PlatformDetails(TypedDict):
    api_level: str
    codename: NotRequired[str]
    base_extension: Literal["true", "false"]
    extension_level: NotRequired[str]
    layoutlib: LayoutLibDict
    
# ./update.py --print-attr-statistics "type_details/attr_xsi_type='sdk:sourceDetailsType'"
class SourceDetails(TypedDict):
    api_level: str
    extension_level: NotRequired[str]
    base_extension: Literal["true", "false"]
    codename: NotRequired[str]

# ./update.py --print-attr-statistics "type_details/attr_xsi_type='generic:genericDetailsType'"
class GenericDetails(TypedDict):
    pass

@dataclass
class License:
    id: str
    text: str

@dataclass
class Channel:
    id: str
    name: str

@dataclass
class AddonPackageDetails:
    api_level: str
    codename: str | None
    is_base_extension: bool
    
@dataclass
class PlatformPackageDetails:
    api_level: str
    codename: str | None
    is_base_extension: bool
    
@dataclass
class SystemImagePackageDetails:
    api_level: str
    codename: str | None
    is_base_extension: bool

@dataclass
class Archive:
    kind: Literal["complete"]
    size: int
    checksum: str
    url: str
    
@dataclass
class Package[D]:
    path: str
    details: D
    revision: str
    uses_license: License
    channel: Channel
    archives: list[Archive] = field(default_factory=list)

@dataclass
class Repository[D]:
    licenses: list[License] = field(default_factory=list)
    channels: list[Channel] = field(default_factory=list)
    packages: list[Package[D]] = field(default_factory=list)
    
    
@dataclass
class AddonRepository(Repository[AddonPackageDetails]):
    pass
    
@dataclass
class PlatformRepository(Repository[PlatformPackageDetails]):
    pass
    
@dataclass
class SystemImageRepository(Repository[SystemImagePackageDetails]):
    pass
    
def extract_licenses(repo_dict: dict[str, Any]) -> list[License]:
    licenses = cast(list[License], [])
    
    for license_dict in repo_dict.get("license", []):
        license = License(
            id=license_dict.get("@id"),
            text=license_dict.get("#text"),
        )
        
        licenses.append(license)
        
    return licenses
        
"""
def parse_repository(repo: dict[str, Any]) -> Generator[AddonRepository | PlatformRepository | SystemImageRepository, None, None]:
    if "addon:sdk-addon" in repo:
        addon_repository = repo.get("addon:sdk-addon")
        addons = AddonRepository()
        
        addons.licenses = parse_licenses(addon_repository.get("license"))
        
        
"""
    

###
### Arguments parsing and script execution
###

@traced()
def resolve_globs_or_paths(patterns: list[str]) -> list[Path]:
    paths = cast(list[Path], [])
    
    for pattern in patterns:
        if not glob.has_magic(pattern):
            paths.append(Path(pattern))
            continue
            
        for path in glob.glob(pattern):
            paths.append(Path(path))
            
    return paths
    
@dataclass
class ScriptArguments:
    verbosity: int
    dir: Path
    skip_default_repositories: bool
    fetch_repositories: list[str]
    read_repositories: list[str]
    print_force_list_heuristic: bool
    print_attr_statistics: list[str]
    
@traced()
def parse_arguments() -> ScriptArguments:
    DEFAULT_DIR = Path(__file__).parent
    
    parser = argparse.ArgumentParser()
    
    _ = parser.add_argument(
        "--verbose", "-v",
        help="Enable verbose logging; specify multiple times to increase the verbosity",
        action="count",
        default=0,
    )
    
    _ = parser.add_argument(
        "--dir",
        help="Directory to store the downloaded repositories; defaults to the script directory",
        type=Path,
        default=str(DEFAULT_DIR)
    )
    
    _ = parser.add_argument(
        "--skip-default-repositories",
        help="Do not fetch the default Android repositories",
        action="store_true",
        default=False,
    )
    
    _ = parser.add_argument(
        "--fetch-repository",
        help="URL of the repository to fetch; specify multiple times to fetch multiple repositories",
        type=str,
        action="append",
        default=[]
    )
    
    _ = parser.add_argument(
        "--read-repository",
        help="Path or glob pattern of the repository to read; specify multiple times to read multiple repositories",
        type=str,
        action="append",
        default=[]
    )
    
    _ = parser.add_argument(
        "--print-force-list-heuristic",
        help="Uses a heuristic to determine which attributes should be forced to be a list",
        action="store_true",
        default=False,
    )
    
    _ = parser.add_argument(
        "--print-attr-statistics",
        help="Prints statistics about the attributes in the repositories; specify multiple times to print statistics for multiple attributes",
        type=str,
        action="append",
        default=[]
    )
    
    args = parser.parse_args()
    
    return ScriptArguments(
        verbosity=args.verbose,
        dir=args.dir,
        skip_default_repositories=args.skip_default_repositories,
        fetch_repositories=args.fetch_repository,
        read_repositories=args.read_repository,
        print_force_list_heuristic=args.print_force_list_heuristic,
        print_attr_statistics=args.print_attr_statistics,
    )


def main() -> int:
    logging.addLevelName(TRACE, "TRACE")
    logging.basicConfig(level=logging.INFO, force=True)
    
    args = parse_arguments()
    
    verbose_trace = args.verbosity >= VERBOSITY_TRACE
    verbose_debug = args.verbosity >= VERBOSITY_DEBUG
    verbose_attr_statistics = args.verbosity >= VERBOSITY_ATTR_STATISTICS
    
    if verbose_debug:
        logging.basicConfig(level=TRACE if verbose_trace else logging.DEBUG, force=True)
    
    repositories_to_fetch = args.fetch_repositories + ([] if args.skip_default_repositories else DEFAULT_REPOSITORIES)
    fetched_paths = fetch_repositories(args.dir, repositories_to_fetch)
    
    repositories_to_read = fetched_paths + resolve_globs_or_paths(args.read_repositories)
    
    if args.print_force_list_heuristic:
        execute_force_list_heuristic(repositories_to_read)

    if len(args.print_attr_statistics) > 0:
        for attr_path in args.print_attr_statistics:
            execute_attr_statistics(repositories_to_read, attr_path, verbose=verbose_attr_statistics)
    
    for path in repositories_to_read:
        repository = convert_repository_to_dict(path)
        (path.parent / f"{path.name}.json").write_text(json.dumps(repository, indent=4))
        

    logger.info(
        "Done. Writing name collisions to collisions.json (please check manually)"
    )
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
