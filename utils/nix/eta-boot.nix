{ mkDerivation, base, binary, bytestring, directory, eta-boot-meta
, filepath, stdenv
}:
mkDerivation {
  pname = "eta-boot";
  # @VERSION_CHANGE@
  version = "0.7.2";
  src = ../../libraries/eta-boot;
  libraryHaskellDepends = [
    base binary bytestring directory eta-boot-meta filepath
  ];
  description = "Shared functionality between Eta and its boot libraries";
  license = stdenv.lib.licenses.bsd3;
}
