#ifndef TREE_SITTER_LANGUAGES_H
#define TREE_SITTER_LANGUAGES_H

#include "api.h"

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_yaml(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_html(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_java(void);

#ifdef __cplusplus
}
#endif

#endif
