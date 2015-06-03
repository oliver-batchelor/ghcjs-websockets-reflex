{ mkDerivation, 
    reflex, 
    reflex-dom, 
    ghcjs-websockets,
    transformers,
    containers,
    text,
    lens,
    binary
}:

mkDerivation {
  pname = "squares-client";
  version = "0.1";
  src = builtins.filterSource (path: type: baseNameOf path != ".git") ./.;
  isExecutable = false;
  buildDepends = [
    reflex
    reflex-dom
    ghcjs-websockets
    containers
    transformers
    text
    lens
    binary
  ];
  license = null;
}
