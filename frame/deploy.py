"""Combined profile deployment and confirmed home integration for Frame sync."""

import os

from home_sync import describe_home_plan, plan_home_sync

from .activation import Activation, handle_cli


def deploy(frame, *, dry_run=False, confirm=None, output=print):
    """Install or update the dedicated profile, then confirm the home integration."""
    frame.activation_config_home()
    activation = Activation(frame)
    font_dir = activation.policy()
    selected = plan_home_sync(
        target="frame",
        home=frame.home,
        repo=frame.repo,
        extra_exclusions=(
            str(frame.state.relative_to(frame.home)),
            str(frame.paths.wrapper.relative_to(frame.home)),
            str(font_dir.relative_to(frame.home)),
        ),
    )
    # Validate local selections without downloading or evaluating Nix expressions.
    _pin, pin_path, override_path = frame.select_sources()
    installed = os.path.lexists(frame.profile)
    action = "update" if installed else "install"
    output(f"Frame profile action: {action}")
    output(f"Source selection: {pin_path}")
    output(f"Package overrides: {override_path or 'none'}")
    if dry_run:
        output("Dry-run: no bootstrap, downloads, builds, profile changes, or activation writes.")
        if installed:
            return handle_cli(frame, dry_run=True, output=output)
        plan = activation.plan(profile="(created by installation)", sync_plan=selected)
        plan.sync_description = describe_home_plan(selected)
        output(plan.describe())
        output("Installation must succeed before the final activation plan can be confirmed.")
        return 0
    output("Profile deployment does not change startup files. Activation asks separately.")
    if installed:
        frame.update()
    else:
        frame.install()
    return handle_cli(frame, confirm=confirm, output=output)
