; Based on tree-sitter-typescript 0.23.2 upstream queries/highlights.scm.
; Loffo additions cover core tokens and keep type matches in type grammar contexts.
; Types

(type_annotation (type_identifier) @type)
(type_arguments (type_identifier) @type)
(predefined_type) @type.builtin
(identifier) @identifier
(shorthand_property_identifier_pattern) @identifier

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

; Variables

(required_parameter (identifier) @variable.parameter)
(optional_parameter (identifier) @variable.parameter)

; Keywords

[ "abstract"
  "declare"
  "const"
  "let"
  "var"
  "function"
  "return"
  "if"
  "else"
  "new"
  "async"
  "await"
  "enum"
  "export"
  "implements"
  "interface"
  "keyof"
  "namespace"
  "private"
  "protected"
  "public"
  "type"
  "readonly"
  "override"
  "satisfies"
] @keyword

; Core lexical tokens omitted by the grammar package's minimal query.
(comment) @comment
(string) @string
(template_string) @string
(number) @number
(regex) @string
(true) @keyword
(false) @keyword
(null) @keyword
