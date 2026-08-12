# Memoize a function for values which can be losslessly converted to data.
#
# Nix cannot grow an attribute set as new keys are discovered.  Instead, use a
# lazy base-4 trie.  Every node has the same four strict keys, while its values
# (and therefore the rest of the trie) remain lazy.  Unsupported values are
# errors unless the caller explicitly requests fallback to the original
# function.
{
  f,
  fallbackOnUnsupported ? false,
}:
let
  encode =
    path: value:
    let
      type = builtins.typeOf value;
    in
    if type == "null" then
      { inherit type; }
    else if type == "bool" || type == "int" || type == "float" then
      {
        inherit type value;
      }
    else if type == "string" then
      {
        inherit type;
        value = builtins.unsafeDiscardStringContext value;
        context = encode (path ++ [ "<string-context>" ]) (builtins.getContext value);
      }
    else if type == "path" then
      {
        inherit type;
        value = builtins.toString value;
      }
    else if type == "list" then
      {
        inherit type;
        value = builtins.genList (index: encode (path ++ [ index ]) (builtins.elemAt value index)) (
          builtins.length value
        );
      }
    else if type == "set" then
      {
        inherit type;
        # Do not encode this as an attribute set: builtins.toJSON treats sets
        # containing outPath specially.  A list also makes the representation
        # unambiguous for every attribute name.
        value = builtins.map (name: {
          inherit name;
          value = encode (path ++ [ name ]) value.${name};
        }) (builtins.attrNames value);
      }
    else if type == "lambda" then
      throw "cannot memoize a function at ${builtins.toJSON path}"
    else
      throw "cannot losslessly encode a value of type ${type} at ${builtins.toJSON path}";

  decode =
    encoded:
    if encoded.type == "null" then
      null
    else if encoded.type == "bool" || encoded.type == "int" || encoded.type == "float" then
      encoded.value
    else if encoded.type == "string" then
      builtins.appendContext encoded.value (decode encoded.context)
    else if encoded.type == "path" then
      /. + encoded.value
    else if encoded.type == "list" then
      builtins.map decode encoded.value
    else if encoded.type == "set" then
      builtins.listToAttrs (
        builtins.map (entry: {
          inherit (entry) name;
          value = decode entry.value;
        }) encoded.value
      )
    else
      throw "invalid memoization encoding type ${builtins.toJSON encoded.type}";

  hexadecimalAlphabet = "0123456789abcdef";
  hexadecimalDigit = number: builtins.substring number 1 hexadecimalAlphabet;
  hexadecimal4 =
    number:
    builtins.concatStringsSep "" (
      builtins.map
        (
          divisor:
          let
            quotient = builtins.div number divisor;
          in
          hexadecimalDigit (quotient - 16 * builtins.div quotient 16)
        )
        [
          4096
          256
          16
          1
        ]
    );
  unicodeCharacter =
    codepoint:
    if codepoint <= 65535 then
      builtins.fromJSON "\"\\u${hexadecimal4 codepoint}\""
    else
      let
        adjusted = codepoint - 65536;
        highSurrogate = 55296 + builtins.div adjusted 1024;
        lowSurrogate = 56320 + adjusted - 1024 * builtins.div adjusted 1024;
      in
      builtins.fromJSON "\"\\u${hexadecimal4 highSurrogate}\\u${hexadecimal4 lowSurrogate}\"";

  # builtins.toJSON produces valid UTF-8.  Construct a corpus containing every
  # byte which may occur in its output: printable ASCII and DEL, all UTF-8
  # continuation bytes, and all valid UTF-8 leading bytes.
  byteCorpus = builtins.concatStringsSep "" (
    builtins.genList (index: unicodeCharacter (32 + index)) 96
    ++ builtins.genList (index: unicodeCharacter (128 + index)) 64
    ++ builtins.genList (index: unicodeCharacter ((2 + index) * 64)) 30
    ++ builtins.genList (index: unicodeCharacter (if index == 0 then 2048 else index * 4096)) 16
    ++ builtins.map unicodeCharacter [
      65536
      262144
      524288
      786432
      1048576
    ]
  );
  stringBytes =
    string: builtins.genList (index: builtins.substring index 1 string) (builtins.stringLength string);
  byteSet = builtins.foldl' (result: byte: result // { ${byte} = null; }) { } (
    stringBytes byteCorpus
  );
  bytes = builtins.attrNames byteSet;

  trieDigit = number: builtins.toString number;
  byteDigits =
    number:
    builtins.concatStringsSep "" (
      builtins.map
        (
          divisor:
          let
            quotient = builtins.div number divisor;
          in
          trieDigit (quotient - 4 * builtins.div quotient 4)
        )
        [
          64
          16
          4
          1
        ]
    );
  byteEntries = builtins.genList (index: {
    byte = builtins.elemAt bytes index;
    digits = byteDigits index;
  }) (builtins.length bytes);
  byteToDigits = builtins.listToAttrs (
    builtins.map (entry: {
      name = entry.byte;
      value = entry.digits;
    }) byteEntries
  );
  digitsToByte = builtins.listToAttrs (
    builtins.map (entry: {
      name = entry.digits;
      value = entry.byte;
    }) byteEntries
  );
  stringToDigits =
    string:
    builtins.concatStringsSep "" (builtins.map (byte: byteToDigits.${byte}) (stringBytes string));
  digitsToString =
    digits:
    builtins.concatStringsSep "" (
      builtins.genList (index: digitsToByte.${builtins.substring (index * 4) 4 digits}) (
        builtins.div (builtins.stringLength digits) 4
      )
    );
  rootPath = {
    key = 0;
  };
  appendDigit = previous: digit: {
    key = previous.key + 1;
    inherit digit previous;
  };
  pathToDigits =
    path:
    let
      reversed = builtins.genericClosure {
        startSet = [ path ];
        operator = entry: if entry ? previous then [ entry.previous ] else [ ];
      };
      digitCount = builtins.length reversed - 1;
    in
    builtins.concatStringsSep "" (
      builtins.genList (index: (builtins.elemAt reversed (digitCount - index - 1)).digit) digitCount
    );

  mkNode =
    path:
    builtins.seq path.key {
      value =
        let
          digits = pathToDigits path;
          encoded = builtins.fromJSON (digitsToString digits);
        in
        f (decode encoded);
      children = {
        "0" = mkNode (appendDigit path "0");
        "1" = mkNode (appendDigit path "1");
        "2" = mkNode (appendDigit path "2");
        "3" = mkNode (appendDigit path "3");
      };
    };
  root = mkNode rootPath;

  lookup =
    digits: (builtins.foldl' (node: digit: node.children.${digit}) root (stringBytes digits)).value;
in
value:
let
  json = builtins.toJSON (encode [ ] value);
  attempted = builtins.tryEval json;
in
if attempted.success then
  lookup (stringToDigits attempted.value)
else if fallbackOnUnsupported then
  f value
else
  # Re-force the encoding to report the original, path-aware error.
  lookup (stringToDigits json)
