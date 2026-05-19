{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.programs.opendeck.enable = lib.mkEnableOption "OpenDeck";

  config = lib.mkIf config.programs.opendeck.enable {
    environment.systemPackages = [ pkgs.opendeck ];
    services.udev.packages = [ pkgs.opendeck ];
  };
}
