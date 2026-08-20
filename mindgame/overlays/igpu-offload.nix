# Renders the terminal and the editor on the AMD iGPU, freeing the VRAM they
# held on the 5090 for the models ananke serves.
#
# The displays are on the 5090, so a client drawing here still hands its
# buffers back across — fine for these two, not for the compositor or
# anything that games. Machine-specific: common-dev-desktop declares both
# packages, but paprika imports that layer and has no iGPU at this address.
final: prev:
let
  # By PCI id: renderD* numbering is not stable across boots.
  igpu = "pci-0000_79_00_0";
  mesaEgl = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
  radvIcd = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";

  # Pinning the vendor library is what makes DRI_PRIME apply at all: glvnd
  # would otherwise hand a Wayland client NVIDIA's EGL, which ignores it.
  glFlags = "--set __EGL_VENDOR_LIBRARY_FILENAMES ${mesaEgl} --set DRI_PRIME ${igpu}";

  # Restricting the loader to RADV leaves nothing else to enumerate.
  vulkanFlags = "--set VK_DRIVER_FILES ${radvIcd}";

  onIgpu = { package, binary, flags }: prev.symlinkJoin {
    name = "${package.pname or package.name}-igpu";
    paths = [ package ];
    nativeBuildInputs = [ prev.makeWrapper ];
    postBuild = "wrapProgram $out/bin/${binary} ${flags}";
  };
in
{
  ghostty = onIgpu {
    package = prev.ghostty;
    binary = "ghostty";
    flags = glFlags;
  };

  zed-editor = onIgpu {
    package = prev.zed-editor;
    binary = "zeditor";
    flags = vulkanFlags;
  };
}
