{
  lib,
  buildPythonPackage,
  exceptiongroup,
  fetchFromGitHub,
  glibcLocales,
  pygobject3,
  pyserial,
  pytestCheckHook,
  pythonOlder,
  pyzmq,
  setuptools,
  setuptools-scm,
  tornado,
  trio,
  twisted,
  typing-extensions,
  wcwidth,
}:

buildPythonPackage rec {
  pname = "urwid";
  version = "2.6.16";
  pyproject = true;

  disabled = pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = "urwid";
    repo = "urwid";
    tag = version;
    hash = "sha256-D5NHtU7XQRh8OqkwrN5r8U/VGF87LGwdnaqGhdjN8AE=";
  };

  postPatch = ''
    sed -i '/addopts =/d' pyproject.toml
  '';

  build-system = [
    setuptools
    setuptools-scm
  ];

  dependencies = [
    typing-extensions
    wcwidth
  ];

  optional-dependencies = {
    glib = [ pygobject3 ];
    tornado = [ tornado ];
    trio = [
      exceptiongroup
      trio
    ];
    twisted = [ twisted ];
    zmq = [ pyzmq ];
    serial = [ pyserial ];
    lcd = [ pyserial ];
  };

  nativeCheckInputs = [
    glibcLocales
    pytestCheckHook
  ]
  ++ lib.flatten (builtins.attrValues optional-dependencies);

  env.LC_ALL = "en_US.UTF8";

  enabledTestPaths = [ "tests" ];

  disabledTests = [
    # Flaky tests
    "TwistedEventLoopTest"
  ];

  disabledTestPaths = [
    # expect call hangs
    "tests/test_vterm.py"
  ];

  pythonImportsCheck = [ "urwid" ];

  meta = with lib; {
    description = "Full-featured console (xterm et al.) user interface library";
    changelog = "https://github.com/urwid/urwid/releases/tag/${version}";
    downloadPage = "https://github.com/urwid/urwid";
    homepage = "https://urwid.org/";
    license = licenses.lgpl21Plus;
    maintainers = [ ];
  };
}
