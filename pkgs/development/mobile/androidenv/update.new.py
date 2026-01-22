#!/usr/bin/env nix-shell
#!nix-shell -I nixpkgs=../../../.. -i python3 -p 'python3.withPackages (ps: with ps; [ beautifulsoup4 lxml pydantic requests returns ])'

### After making change:
### - Format the script by running: nix run nixpkgs#black pkgs/development/mobile/androidenv/update.py
### - Run the unit test by running: python3 -m unittest pkgs/development/mobile/androidenv/update.py
### - Run the type checking by running: nix run nixpkgs#mypy pkgs/development/mobile/androidenv/update.py

# pyright: basic

from abc import ABC, ABCMeta, abstractmethod, abstractproperty
import abc
import argparse
from collections.abc import Iterable
from datetime import date
import hashlib
import logging
from pathlib import Path
from typing import Concatenate, List
from bs4.element import AttributeValueList, PageElement
from typing_extensions import Annotated, Hashable, Literal, Never, NotRequired, Callable, get_args, get_origin, get_type_hints, overload, override
import requests
import functools
import sys
from urllib.parse import urlparse, urljoin
from bs4 import BeautifulSoup, Tag
import pydantic
from pydantic.dataclasses import dataclass
from dataclasses import dataclass as pydataclass, field
from returns.maybe import maybe, Some, Maybe, Nothing
from returns.pipeline import flow

###
### Global variables
###

logger = logging.getLogger(__name__)

###
### Global constants
###

TRACE = 5
VERBOSITY_DEBUG = 1
VERBOSITY_TRACE = 2

###
### Generic functions
###

@pydataclass
class Trace:
    visible: bool

def traced(hide_return: bool = False):
    """
    Decorator to log function calls, arguments and return values.
    """

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
def make_session() -> requests.Session:
    """
    Returns a session that can be used to make requests.
    """

    session = requests.session()
    session.headers["User-Agent"] = "nixpkgs androidenv update bot"
    return session

###
### 1. Fetch manifests from the given URLs
###

@traced()
def resolve_url(url: str) -> str:
    """
    Returns the resolved URL.
    If the "android" scheme is used, then the URL is resolved relative to the
    official Google android repository location. Otherwise, the URL is returned as-is.

    For instance, "android:./repository2-3.xml" resolves to "https://dl.google.com/android/repository/repository2-3.xml".
    """

    parsed_url = urlparse(url)
    match parsed_url.scheme:
        case "android":
            return urljoin("https://dl.google.com/android/repository/", parsed_url.path)
        case "":
            raise ValueError(f"Invalid URL: {url}")
        case _:
            return url

@traced()
def resolve_url_relative_to(base_url: str, relative: str) -> str:
    """
    Resolves a path or URL relative to a given URL base.

    This is used for resolving archive URLs relative to the repository URL.
    """

    # The archive URLs must be resolved relative to the repository URL.
    # That is, if "https://dl.google.com/android/repository/repository2-3.xml"
    # has an archive with URL equal to "platform-36.1_r01.zip", then the
    # resolved URL should be "https://dl.google.com/android/repository/platform-36.1_r01.zip".
    url = urljoin(resolve_url(base_url), relative)
    return resolve_url(url)
    
@pydataclass
class Manifest:
    url: str
    text: str

@traced()
def fetch_manifest(session: requests.Session, manifest_url: str) -> Manifest:
    """
    Fetches the given URL and returns the manifest at that URL.
    """
    
    url = resolve_url(manifest_url)
    parsed_url = urlparse(url)
    match parsed_url.scheme:
        case "file":
            source_file = Path(parsed_url.path)
            with source_file.open(mode="rb", encoding="utf-8") as file:
                return Manifest(url, file.read())
        case _:
            with session.get(url, timeout=10) as response:
                response.raise_for_status()
                return Manifest(url, response.content.decode(encoding="utf-8"))

###
### 2. Data structures to store repository information
###

class BaseKeyer[T, K: Hashable](ABC):
    labels: list[str] | None
    
    def __init__(self):
        try:
            self.labels
        except AttributeError:
            raise AttributeError(f"{self.__class__} must define a 'labels' attribute")
    
    @abstractmethod
    def make_key(self, value: T) -> K:
        ...

class KeyedCollection[T, K: Hashable]:
    type ConflictResolution = Literal["error", "ignore", "replace"]
    
    # Ideally, we would do something like
    # `class KeyedCollection[K: Hashable, T: Keyed[K]]` and then call `to_key`
    # directly, but Python does not support that yet. So we have to decouple the
    # KeyedCollection type from the Keyed type by receiving a keyer function as
    # a parameter.
    # To make this easier to use, we also have a KeyedCollection.of_keyed() method
    # that returns a KeyedCollection with the correct type parameters and keyer
    # function.
    # See https://github.com/python/typing/issues/548.
    def __init__(self, keyer: BaseKeyer[T, K]):
        self.inner = dict[K, T]()
        self.keyer = keyer
        
    def key_for(self, value: T) -> K:
        return self.keyer.make_key(value)

    def add(self, value: T, on_conflict: ConflictResolution = "error") -> None:
        key = self.key_for(value)
        if on_conflict == "replace" or key not in self.inner:
            self.inner[key] = value
            return
            
        if on_conflict == "error":
            raise ValueError(f"Key {key} already exists in the collection")
        
    def update(self, values: Iterable[T], on_conflict: ConflictResolution = "error") -> None:
        for value in values:
            self.add(value, on_conflict)

    def remove(self, value: T) -> None:
        del self.inner[self.key_for(value)]

    def __getitem__(self, key: K) -> T:
        return self.inner[key]
        
    def __iter__(self):
        return iter(self.inner.values())


@dataclass(init=False, unsafe_hash=True)
class Archive:
    arch: Literal["all", "aarch64", "x64", "x86"]
    os: Literal["all", "linux", "macosx", "windows"]
    url: str
    sha1: str
    size: int
    
    # This is used to remove all type-safety from the initializer.
    # Useful to pass all of the attributes of an XML node to the constructor
    # without having to specify the name of all parameters.
    def __init__(self, **kwargs): ...
    
@dataclass(init=False, unsafe_hash=True)
class Dependency:
    path: str
    revision: str | None = None
    
    def __init__(self, **kwargs): ...

@dataclass(init=False, unsafe_hash=True)
class Package:
    path: str
    revision: str
    kind: Literal["addon", "extra", "generic", "platform", "source", "system-image"]
    channel: str
    last_available_at: date
    obsolete: bool = False
    uses_license: str | None = None
    archives: list[Archive] = field(default_factory=list)
    dependencies: list[Dependency] = field(default_factory=list)
    
    type PackageKey = tuple[str, str]

    def __init__(self, **kwargs): ...
    
    class Keyer(BaseKeyer["Package", "Package.PackageKey"]):
        labels = ["packages", "revisions"]
        
        @override
        def make_key(self, value) -> "Package.PackageKey":
            # The unique identifier of a package is (path, revision).
            return (value.path, value.revision)

@dataclass(init=False, unsafe_hash=True)
class License:
    id: str
    text: str
    
    type LocalLicenseKey = str
    type GlobalLicenseKey = tuple[str, str]
    
    def __init__(self, **kwargs): ...
    
    def hexdigest(self) -> str:
        """
        Returns the SHA-256 hash of the license text.

        This is used to handle changes in the license text over time.
        """

        return hashlib.sha256(self.text.encode("utf-8")).hexdigest()

    class LocalKeyer(BaseKeyer["License", "License.LocalLicenseKey"]):
        labels = None
        
        # Within the same repository (local context), just referring to a license
        # by its ID is enough to uniquely identify it.
        @override
        def make_key(self, value) -> "License.LocalLicenseKey":
            return value.id
            
    class GlobalKeyer(BaseKeyer["License", "License.GlobalLicenseKey"]):
        labels = ["licenses", "revisions"]
        
        # However, as time goes by and multiple repositories (and versions of the
        # same repository) are merged (global context), the license text might change.
        # Therefore, we need to include the digest of the license text in the key.
        @override
        def make_key(self, value) -> "License.GlobalLicenseKey":
            return (value.id, value.hexdigest())

@dataclass(init=False, unsafe_hash=True)
class Channel:
    id: str
    name: str
    
    type LocalChannelKey = str
    
    def __init__(self, **kwargs): ...
    
    class LocalKeyer(BaseKeyer["Channel", "Channel.LocalChannelKey"]):
        labels = None
        
        # Within the same repository (local context), just referring to a channel
        # by its ID is enough to uniquely identify it.
        @override
        def make_key(self, value) -> "Channel.LocalChannelKey":
            return value.id

###
### 3. Parsing of the manifests
###

class Xml:
    @staticmethod
    def text(node: PageElement):
        text = node.get_text()
        if not text:
            raise ValueError("Node does not have text")
            
        return text
    
    @staticmethod
    def attribute(tag: Tag, name: str):
        if name not in tag.attrs:
            raise KeyError(f"Node does not have attribute {name}")
            
        value = tag.attrs.get(name)
        if not isinstance(value, str):
            raise ValueError("Attribute is not a string")
            
        return value
        
    @staticmethod
    @maybe
    def maybe_attribute(tag: Tag, name: str):
        try:
            return Xml.attribute(tag, name)
        except KeyError:
            return None

    @staticmethod
    def select_many(tag: Tag, css: str):
        return tag.css.select(css)
        
    @staticmethod
    @maybe
    def select_one(tag: Tag, css: str):
        return tag.css.select_one(css)

class ManifestParser:
    def __init__(self, manifest: Manifest):
        self.manifest_url = manifest.url
        self.root = BeautifulSoup(manifest.text, "lxml-xml")
    
    @traced()
    def parse_license(self, license_node: Annotated[Tag, Trace(visible=False)]) -> License:
        license_type = Xml.attribute(license_node, "type")
        assert license_type == "text", f"Only text licenses are supported, found {license_type}"
        
        return License(
            **license_node.attrs,
            text=Xml.text(license_node))
        
    @traced()
    def parse_licenses(self) -> set[License]:
        return set(self.parse_license(license_node) for license_node in Xml.select_many(self.root, "license"))
            
    @traced()
    def parse_channel(self, channel_node: Annotated[Tag, Trace(visible=False)]) -> Channel:
        name = Xml.text(channel_node)
        return Channel(
            **channel_node.attrs,
            name=name)
        
    @traced()
    def parse_channels(self) -> set[Channel]:
        return set(self.parse_channel(channel_node) for channel_node in Xml.select_many(self.root, "channel"))
        
    @traced()
    def parse_archive(self, archive_node: Annotated[Tag, Trace(visible=False)]) -> Archive:
        host_os = flow(archive_node, Xml.select_one("& > host-os"))
        host_arch = Maybe.do(Xml.text(node) for node in Xml.select_one(archive_node, "& > host-arch")).value_or("all")
        size = Maybe.do(int(Xml.text(node)) for node in Xml.select_one(archive_node, "& > complete > size")).unwrap()
        sha1 = self.extract_text(self.select_one(archive_node, '& > complete > checksum[type="sha1"]'))
        relative_url = self.extract_text(self.select_one(archive_node, "& > complete > url"))
        
        url = resolve_url_relative_to(self.manifest_url, relative_url)
        return Archive(
            arch=host_arch,
            os=host_os,
            url=url,
            sha1=sha1,
            size=size)
        
    @traced()
    def parse_dependency(self, dependency_node: Annotated[Tag, Trace(visible=False)]) -> Dependency:
        path = self.extract_attribute(dependency_node, "path")
        revision = self.select_maybe_one(dependency_node, "& > min-revision")
        if revision is not None:
            revision = self.parse_revision(revision)
            
        return Dependency(
            path=path,
            revision=revision,
        )
        
    @traced()
    def parse_revision(self, revision_node: Annotated[Tag, Trace(visible=False)]) -> str:
        major = self.extract_text(self.select_one(revision_node, "& > major"))
        minor = self.extract_text(self.select_maybe_one(revision_node, "& > minor"))
        micro = self.extract_text(self.select_maybe_one(revision_node, "& > micro"))
        preview = self.extract_text(self.select_maybe_one(revision_node, "& > preview"))
        
        # Converting the revision to a string must obey a few rules to ensure
        # that sorting the resulting string is consistent with the expected
        # ordering of the revisions in the repository.
      
        revision = major
        # Minor and micro are assumed to be 0 if not present.
        # This would be a problem if, for instance,
        # the revision "20" is considered newer than "20.0",
        # which doesn't seem to be the case.
        revision += f".{minor or '0'}"
        revision += f".{micro or '0'}"
        # The preview number is optionally included in the revision
        # because "20.0" is considered newer than "20.0-preview01",
        # for instance.
        if preview:
            revision += f"-preview{preview}"
            
        return revision
        
    @traced(hide_return=True)
    def parse_package(self, package_node: Annotated[Tag, Trace(visible=False)]) -> Package:
        path = self.extract_attribute(package_node, "path")
        uses_license = self.extract_attribute(self.select_maybe_one(package_node, "& > uses-license"), "ref")
        channel_ref = self.extract_attribute(self.select_one(package_node, "& > channelRef"), "ref")
        channel = self.extract_text(self.select_one(self.root, f"channel[id='{channel_ref}']"))
        revision = self.parse_revision(self.select_one(package_node, "& > revision"))
        archives = set(self.parse_archive(archive_node) for archive_node in self.select_many(package_node, "& > archives > archive"))
        last_available_at = date.today()
        obsolete = self.extract_maybe_attribute(package_node, "obsolete") == "true"
        dependencies = set(self.parse_dependency(dependency_node) for dependency_node in self.select_many(package_node, "& > dependencies > dependency"))
        
        return Package(
            path=path,
            revision=revision,
            kind="generic",
            channel=channel,
            uses_license=uses_license,
            last_available_at=last_available_at,
            obsolete=obsolete,
            archives=archives,
            dependencies=dependencies,
        )
            
            
    @traced()
    def parse_packages(self) -> KeyedCollection[Package, Package.PackageKey]:
        collection = KeyedCollection(Package.Keyer())
        collection.update(self.parse_package(package_node) for package_node in self.select_many(self.root, "remotePackage"))
        return collection
            
        
    
    @traced(hide_return=True)
    def parse(self):
        print(self.parse_licenses())
        print(self.parse_channels())
        print(self.parse_packages())
        return
        

@traced(hide_return=True)
def parse_licenses(repository_node: Annotated[Tag, Trace(visible=False)]):
    licenses = KeyedCollection(License.LocalKeyer())

    

    return licenses
    
@traced()
def parse_channels(repository_node: Annotated[Tag, Trace(visible=False)]):
    channels = KeyedCollection(Channel.LocalKeyer())
    
    for channel_node in repository_node.css.select("channel"):
        channel = Channel(
            **channel_node.attrs,
            name=channel_node.get_text())
        
        channels.add(channel)
        
    return channels
    
@traced(hide_return=True)
def parse_packages(repository_node: Annotated[Tag, Trace(visible=False)]) -> set[Package]:
    pass

@traced()
def parse_repository(manifest: Manifest):
    parser = ManifestParser(manifest)
    return parser.parse()







###
### 4. Generating changelogs
###

@dataclass
class Diff[T]:
    """
    Represents changes in a set of items.

    This is used to create a changelog of changes in the repository.
    """

    added: set[T]
    removed: set[T]
    changed: set[tuple[T, T]]

def generate_diff[T, K: Hashable](keyer: BaseKeyer[T, K], before: set[T], after: set[T]) -> Diff[T]:
        """
        Generates a diff between two sets of items.
        """

        before_dict = { keyer.make_key(item): item for item in before }
        after_dict = { keyer.make_key(item): item for item in after }

        added_keys = after_dict.keys() - before_dict.keys()
        removed_keys = before_dict.keys() - after_dict.keys()
        maintained_keys = after_dict.keys() & before_dict.keys()

        added_items = set(after_dict[key] for key in added_keys)
        removed_items = set(before_dict[key] for key in removed_keys)
        changed_items = set((before_dict[key], after_dict[key]) for key in maintained_keys if before_dict[key] != after_dict[key])

        return Diff(added=added_items, removed=removed_items, changed=changed_items)

###
### 4. Arguments parsing and script execution
###

@dataclass
class ScriptArguments:
    verbosity: int
    dir: Path
    repositories: list[str]

@traced()
def parse_arguments() -> ScriptArguments:
    DEFAULT_DIR = Path(__file__).parent

    ##
    ## These are the default repositories that will be fetched if the user does not provide any.
    ## Fetching these repositories can be disabled by passing the --skip-default-repositories flag.
    ##
    DEFAULT_REPOSITORIES = [
        "android:./repository2-3.xml",
        "android:./sys-img/android/sys-img2-3.xml",
        "android:./sys-img/android-tv/sys-img2-3.xml",
        "android:./sys-img/android-wear/sys-img2-3.xml",
        "android:./sys-img/android-wear-cn/sys-img2-3.xml",
        "android:./sys-img/android-automotive/sys-img2-3.xml",
        "android:./sys-img/google_apis/sys-img2-3.xml",
        "android:./sys-img/google_apis_playstore/sys-img2-3.xml",
        "android:./addon2-3.xml",
    ]

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
        "--repository",
        help="URL of the repository to fetch (supports file URLs); specify multiple times to fetch multiple repositories",
        type=str,
        action="append",
        default=DEFAULT_REPOSITORIES,
    )

    args = parser.parse_args()

    return ScriptArguments(
        verbosity=args.verbose,
        dir=args.dir,
        repositories=args.repository,
    )


def main() -> int:
    logging.addLevelName(TRACE, "TRACE")
    logging.basicConfig(level=logging.INFO, force=True)

    args = parse_arguments()

    verbose_trace = args.verbosity >= VERBOSITY_TRACE
    verbose_debug = args.verbosity >= VERBOSITY_DEBUG

    if verbose_debug:
        logging.basicConfig(level=TRACE if verbose_trace else logging.DEBUG, force=True)

    with make_session() as session:
        for manifest_url in args.repositories:
            manifest = fetch_manifest(session, manifest_url)
            repository = parse_repository(manifest)
            #print(manifest, repository)
            break

    logger.info(
        "Done. Writing name collisions to collisions.json (please check manually)"
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
