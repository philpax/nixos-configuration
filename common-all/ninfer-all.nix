# The iamwavecut/ninfer-all line, shared by both machines.
#
# It carries the `gguf_blocks_v1` loader the GGUF-repackaged artifacts (Swift
# GSQ-RCO and Inkling 2 Mini) need; upstream ninfer cannot load those. The
# Ryan-gsq fork the Swift card names also can, but predates the fix for
# creating its cuBLAS handle under graph capture, so wide verify graphs fail
# at startup there.
#
# One revision for both hosts: mindgame builds it from source for sm_120a,
# redline pulls the prebuilt CUDA 12.9 multiarch image (which includes
# sm_86). The revision is release 2026-11-23.7, whose Inkling 2 prompt
# near/far-field tensor-core work and fused q/kv epilogues are the ones the
# 3090 measurements use.
{ pkgs }:

let
  revision = "c3e6ea10289073dda50eebb0e18e11eba457c8b6";
in
{
  inherit revision;

  # `nix-prefetch-url --unpack` of the GitHub tarball, converted to SRI.
  source = pkgs.fetchFromGitHub {
    owner = "iamwavecut";
    repo = "ninfer-all";
    rev = revision;
    hash = "sha256-kjxnXa5Epm1c+VITJqg9VeUfgIJw/enLUgJWwn1OVWc=";
  };

  # Commit-named image tags are immutable; the digests are the index digests
  # those tags resolved to when this pin was written. Redline uses the
  # CUDA 12.9 line because it is what that host already runs; the CUDA 13.4
  # digest is kept beside it so a Blackwell host can pin the same revision.
  images = {
    cuda12_9 = {
      ref = "ghcr.io/iamwavecut/ninfer-all";
      digest = "sha256:b99175e1510f69cc8ab42b4c4fdf92c5ebc4ecc4b2f9c0a87a83fb0c8fbc64fc";
    };
    cuda13_4 = {
      ref = "ghcr.io/iamwavecut/ninfer-all";
      digest = "sha256:48edc47fc63eb2a90b186288be9e90d656ce5849118fb2f2738f0da612818d67";
    };
  };

  # The published v3 artifact both hosts serve. Its vision tower requires
  # commit 7fcbbb13 or later, which this revision is.
  inkling2Mini = {
    modelId = "inkling-2-mini";
    artifact = "Inkling-2-Mini-UD-IQ4_XS-ninfer-v3.ninfer";
    sha256 = "a4a1bbfbdc1150cecc9df2bc12ae87c076330bff81579e243e7875115329bb54";
  };
}
