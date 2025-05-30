{
  lib,
  asn1crypto,
  asysocks,
  buildPythonPackage,
  fetchPypi,
  oscrypto,
  pythonOlder,
  six,
  tqdm,
  unicrypto,
}:

buildPythonPackage rec {
  pname = "minikerberos";
  version = "0.4.6";
  format = "setuptools";

  disabled = pythonOlder "3.7";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-Vv04ngYZcEO32J7ucT6aXyu1RgINtqBk4ZIddA+VcpA=";
  };

  propagatedBuildInputs = [
    asn1crypto
    asysocks
    oscrypto
    six
    tqdm
    unicrypto
  ];

  # no tests are published: https://github.com/skelsec/minikerberos/pull/5
  doCheck = false;

  pythonImportsCheck = [ "minikerberos" ];

  meta = with lib; {
    description = "Kerberos manipulation library in Python";
    homepage = "https://github.com/skelsec/minikerberos";
    changelog = "https://github.com/skelsec/minikerberos/releases/tag/${version}";
    license = with licenses; [ mit ];
    maintainers = with maintainers; [ fab ];
  };
}
