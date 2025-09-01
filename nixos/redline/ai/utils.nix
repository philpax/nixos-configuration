{ pkgs, ... }:
{
  # Helper function to create a service configuration
  mkService = {
    name, listenPort, targetPort, command, killCommand ? null, args, healthcheck ? null, restartOnConnectionFailure ? false,
    resourceRequirements, shutDownAfterInactivitySeconds ? 120, openaiApi ? false
  }: {
    Name = name;
    ListenPort = toString listenPort;
    ProxyTargetHost = "localhost";
    ProxyTargetPort = toString targetPort;
    Command = command;
    Args = args;
    KillCommand = killCommand;
    OpenAiApi = openaiApi;
    RestartOnConnectionFailure = restartOnConnectionFailure;
    ResourceRequirements = resourceRequirements;
    ShutDownAfterInactivitySeconds = shutDownAfterInactivitySeconds;
  } // (if healthcheck != null then {
    HealthcheckCommand = healthcheck.command;
    HealthcheckIntervalMilliseconds = healthcheck.intervalMilliseconds;
  } else {});
}