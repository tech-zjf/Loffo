; Tree-sitter Markdown v0.5.1. Fenced blocks are kept as code; injections are not enabled.
(atx_heading (inline) @heading)
(setext_heading (paragraph) @heading)
[
  (atx_h1_marker) (atx_h2_marker) (atx_h3_marker)
  (atx_h4_marker) (atx_h5_marker) (atx_h6_marker)
  (setext_h1_underline) (setext_h2_underline)
  (list_marker_plus) (list_marker_minus) (list_marker_star)
  (list_marker_dot) (list_marker_parenthesis)
  (thematic_break) (block_quote_marker)
] @markup
(fenced_code_block) @code
(indented_code_block) @code
