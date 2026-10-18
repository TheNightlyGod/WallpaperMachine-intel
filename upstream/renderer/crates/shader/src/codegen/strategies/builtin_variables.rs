//! Builtin variables spelled the way the Direct3D dialect spells them.

use linkme::distributed_slice;

use super::{
    BUILTIN_VARIABLES, CodegenStage, CodegenStrategy, Emitable, GENERAL_POLICIES, StrategyContext,
};
use crate::{
    ShaderResult,
    codegen::{
        Fixup,
        declarations::builtins::{self, VULKAN_SPELLING},
    },
    syntax::{PreprocessorDirective, SyntaxItem},
    tokenizer::{TokenCursor, TypedToken},
};

/// Renames the builtin variables a stage reads under their OpenGL names.
struct BuiltinVariablesStrategy;

#[distributed_slice(GENERAL_POLICIES)]
static BUILTIN_VARIABLES_POLICY: CodegenStrategy = CodegenStrategy {
    name: BUILTIN_VARIABLES,
    stage: CodegenStage::CompatibilityExpansion,
    after: &[],
    emitter: &BuiltinVariablesStrategy,
};

impl Emitable for BuiltinVariablesStrategy {
    fn emit(&self, context: &mut StrategyContext<'_, '_, '_>) -> ShaderResult<()> {
        let module = context.context().module;
        // A stage that declares one of these names as anything but the
        // builtin's `uint` uses its own variable of that name.
        let own: Vec<&str> = module
            .items()
            .iter()
            .filter_map(|item| match item {
                SyntaxItem::Declaration(declaration) if declaration.qualifier().is_some() => {
                    let name = declaration.name()?;
                    let restated = builtins::is_restated(name, declaration.type_name().unwrap_or_default());
                    (!restated).then_some(name)
                },
                _ => None,
            })
            .collect();
        let tokens = module.token_stream().cursor();
        Self::rename_in(context, tokens, &own);

        // A macro replacement is renamed where it is written, however deeply
        // the directive sits inside a function body.
        for token in tokens.iter() {
            if !matches!(token.kind(), TypedToken::Directive(_)) {
                continue;
            }
            let directive =
                PreprocessorDirective::from_token_text(module.slice(token.span()), token.span());
            let Some(body) = directive.define_body_tokens_in(module)? else {
                continue;
            };
            Self::rename_in(context, body.cursor(), &own);
        }
        Ok(())
    }
}

impl BuiltinVariablesStrategy {
    /// Pushes a rename for every OpenGL-spelled builtin in `tokens`.
    fn rename_in(context: &mut StrategyContext<'_, '_, '_>, tokens: TokenCursor<'_>, own: &[&str]) {
        for token in tokens.identifiers() {
            if let Some((_, vulkan)) = VULKAN_SPELLING
                .iter()
                .find(|(opengl, _)| *opengl == token.text() && !own.contains(opengl))
            {
                context
                    .context()
                    .fixups
                    .push(Fixup::replace(token.span(), *vulkan));
            }
        }
    }
}
