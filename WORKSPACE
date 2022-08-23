load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

http_archive(
    name = "bazel_skylib",
    sha256 = "af87959afe497dc8dfd4c6cb66e1279cb98ccc84284619ebfec27d9c09a903de",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.2.0/bazel-skylib-1.2.0.tar.gz",
        "https://github.com/bazelbuild/bazel-skylib/releases/download/1.2.0/bazel-skylib-1.2.0.tar.gz",
    ],
)

load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")

bazel_skylib_workspace()

http_archive(
    name = "rules_pkg",
    sha256 = "a89e203d3cf264e564fcb96b6e06dd70bc0557356eb48400ce4b5d97c2c3720d",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/rules_pkg/releases/download/0.5.1/rules_pkg-0.5.1.tar.gz",
        "https://github.com/bazelbuild/rules_pkg/releases/download/0.5.1/rules_pkg-0.5.1.tar.gz",
    ],
)

load("@rules_pkg//:deps.bzl", "rules_pkg_dependencies")

rules_pkg_dependencies()

http_archive(
    name = "io_bazel_rules_docker",
    sha256 = "b1e80761a8a8243d03ebca8845e9cc1ba6c82ce7c5179ce2b295cd36f7e394bf",
    urls = ["https://github.com/bazelbuild/rules_docker/releases/download/v0.25.0/rules_docker-v0.25.0.tar.gz"],
)

load(
    "@io_bazel_rules_docker//repositories:repositories.bzl",
    container_repositories = "repositories",
)

container_repositories()

load("@io_bazel_rules_docker//repositories:deps.bzl", container_deps = "deps")

container_deps()

load(
    "@io_bazel_rules_docker//container:container.bzl",
    "container_pull",
)

container_pull(
    name = "ubuntu2004",
    registry = "index.docker.io",
    repository = "pivotalrabbitmq/ubuntu",
    tag = "20.04",
)

http_file(
    name = "openssl-1.1.1g",
    downloaded_file_path = "openssl-1.1.1g.tar.gz",
    sha256 = "ddb04774f1e32f0c49751e21b67216ac87852ceb056b75209af2443400636d46",
    urls = ["https://www.openssl.org/source/openssl-1.1.1g.tar.gz"],
)

http_file(
    name = "otp_src_23",
    downloaded_file_path = "OTP-23.3.4.16.tar.gz",
    sha256 = "ff091e8a2b3e6350b890d37123444474cf49754f6add0ccee17582858ee464e7",
    urls = ["https://github.com/erlang/otp/archive/OTP-23.3.4.16.tar.gz"],
)

http_file(
    name = "otp_src_24",
    downloaded_file_path = "OTP-24.3.4.3.tar.gz",
    sha256 = "35047470fd7064b902c0df1d01d19051a20213eeeac4ad9b21a6ce4129c2c139",
    urls = ["https://github.com/erlang/otp/archive/OTP-24.3.4.3.tar.gz"],
)

http_file(
    name = "otp_src_25",
    downloaded_file_path = "OTP-25.0.3.tar.gz",
    sha256 = "e8eca69b6bdaac9cc8f3e3177dd2913920513495ee83bdecf73af546768febd6",
    urls = ["https://github.com/erlang/otp/archive/OTP-25.0.3.tar.gz"],
)

http_archive(
    name = "io_buildbuddy_buildbuddy_toolchain",
    sha256 = "a2a5cccec251211e2221b1587af2ce43c36d32a42f5d881737db3b546a536510",
    strip_prefix = "buildbuddy-toolchain-829c8a574f706de5c96c54ca310f139f4acda7dd",
    urls = ["https://github.com/buildbuddy-io/buildbuddy-toolchain/archive/829c8a574f706de5c96c54ca310f139f4acda7dd.tar.gz"],
)

load("@io_buildbuddy_buildbuddy_toolchain//:deps.bzl", "buildbuddy_deps")

buildbuddy_deps()

load("@io_buildbuddy_buildbuddy_toolchain//:rules.bzl", "buildbuddy")

buildbuddy(
    name = "buildbuddy_toolchain",
    llvm = True,
)

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "rbe",
    commit = "e96d11e9b2ca5bc7e7256957e718d268ddf3be35",  # linux-rbe branch
    remote = "https://github.com/rabbitmq/rbe-erlang-platform.git",
)

git_repository(
    name = "rules_erlang",
    remote = "https://github.com/rabbitmq/rules_erlang.git",
    tag = "3.2.0",
)

load(
    "@rules_erlang//:rules_erlang.bzl",
    "rules_erlang_dependencies",
)

rules_erlang_dependencies()

register_toolchains(
    "//bazel/toolchains:erlang_toolchain_external",
    "//bazel/toolchains:erlang_toolchain_23",
    "//bazel/toolchains:erlang_toolchain_24",
    "//bazel/toolchains:erlang_toolchain_25",
    "//bazel/toolchains:erlang_toolchain_git_master",
    "//bazel/toolchains:elixir_toolchain_external",
    "//bazel/toolchains:elixir_toolchain_1_10",
    "//bazel/toolchains:elixir_toolchain_1_12",
    "//bazel/toolchains:elixir_toolchain_1_13",
)

load("//:workspace_helpers.bzl", "rabbitmq_external_deps")

rabbitmq_external_deps(rabbitmq_workspace = "@")

load("//deps/amqp10_client:activemq.bzl", "activemq_archive")

activemq_archive()

load("//bazel/bzlmod:secondary_umbrella.bzl", "secondary_umbrella")

secondary_umbrella()
