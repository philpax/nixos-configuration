{
  # Thin wrapper around upstream llama.cpp's own flake. Upstream ships a
  # flake.nix but no flake.lock, so it can't be consumed directly from our
  # channels-based config under pure evaluation. This wrapper pins it (and its
  # transitive inputs) via the committed flake.lock here, and re-exports its
  # packages. Consumed from ../default.nix via flake-compat.
  #
  # To move to a newer llama.cpp tag: change the rev below, then run
  #   nix flake update llama-cpp
  # in this directory and commit the updated flake.lock.
  description = "Pinned upstream llama.cpp flake for redline's AI services";

  inputs.llama-cpp.url = "github:ggml-org/llama.cpp/b9444";

  outputs = { llama-cpp, ... }: { inherit (llama-cpp) packages; };
}
