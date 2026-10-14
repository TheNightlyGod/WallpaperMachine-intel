//! Global variables initialized from runtime values.

use linkme::distributed_slice;
use smol_str::SmolStr;

use super::{
    CodegenStage, CodegenStrategy, Emitable, GENERAL_POLICIES, GLOBAL_INITIALIZERS, StrategyContext,
};
use crate::{
    ShaderResult, SourceSpan,
    codegen::Fixup,
    syntax::{DeclarationKind, SyntaxItem},
    tokenizer::{DeclarationFact, KeywordType, TokenCursor, TokenIndexRange, TypedToken},
};

/// Evaluates global initializers that read runtime values at the start of
/// `main`.
///
/// GLSL wants a constant expression there. A `const` global initialized from a
/// uniform is rejected outright, taking the whole effect with it, and a mutable
/// one is accepted with its initializer silently dropped, so it reads zero. The
/// permissive path these shaders target evaluates the initializer once the
/// uniforms are bound. The initializer stays where it is, so every other edit
/// inside it still applies, wrapped in a function `main` calls first:
///
/// `const float F = u_x * 0.5;` becomes
/// `float F; void _we_init_F() { F = u_x * 0.5; }`.
///
/// Only an initializer that reads something known to change at run time
/// moves: a uniform, a texture, a stage input, a mutable or moved global, a
/// user function or a `gl_` builtin. Anything else may be a constant
/// expression an array size depends on, and stays one.
struct GlobalInitializersStrategy;

#[distributed_slice(GENERAL_POLICIES)]
static GLOBAL_INITIALIZERS_POLICY: CodegenStrategy = CodegenStrategy {
    name: GLOBAL_INITIALIZERS,
    stage: CodegenStage::SemanticRewrite,
    after: &[],
    emitter: &GlobalInitializersStrategy,
};

impl Emitable for GlobalInitializersStrategy {
    fn emit(&self, context: &mut StrategyContext<'_, '_, '_>) -> ShaderResult<()> {
        let module = context.context().module;
        let tokens = module.token_stream().cursor();
        let declarations = module.token_facts().declarations();
        let mut runtime = module
            .functions()
            .iter()
            .map(|function| SmolStr::new(function.name()))
            .collect::<Vec<_>>();
        let mut fixups = Vec::new();
        let mut moved = Vec::new();

        for item in module.items() {
            let SyntaxItem::Declaration(declaration) = item else {
                continue;
            };
            if declaration.qualifier().is_some() {
                runtime.extend(declaration.name().map(SmolStr::new));
                continue;
            }
            if declaration.kind() != DeclarationKind::Other {
                continue;
            }
            let Some(range) =
                tokens.contained_byte_range(declaration.span().start(), declaration.span().end())
            else {
                continue;
            };
            let declarators = declarations
                .iter()
                .filter(|fact| {
                    range.start() <= fact.name_index() && fact.name_index() < range.end()
                })
                .collect::<Vec<_>>();
            let Some(first) = declarators.first() else {
                continue;
            };
            let Some(qualifiers) = Qualifiers::scan(tokens, range.start(), first.type_index())
            else {
                continue;
            };
            let names = declarators.iter().map(|fact| fact.name().clone());
            let [declarator] = declarators.as_slice() else {
                if qualifiers.constant.is_none() {
                    runtime.extend(names);
                }
                continue;
            };
            let reads_runtime = declarator.initializer().is_some_and(|initializer| {
                Self::reads_runtime_value(tokens, initializer, &runtime)
            });
            if !reads_runtime {
                if qualifiers.constant.is_none() {
                    runtime.extend(names);
                }
                continue;
            }
            let Some(edits) = Self::wrap_initializer(tokens, declarator, qualifiers) else {
                continue;
            };
            fixups.extend(edits);
            runtime.push(declarator.name().clone());
            moved.push(declarator.name().clone());
        }

        let context = context.context();
        for fixup in fixups {
            context.fixups.push(fixup);
        }
        context.declarations.global_initializers.extend(moved);
        Ok(())
    }
}

impl GlobalInitializersStrategy {
    /// Returns whether an initializer reads a value only known at run time.
    #[expect(
        clippy::single_call_fn,
        reason = "names the runtime-read rule the declaration scan applies"
    )]
    fn reads_runtime_value(
        tokens: TokenCursor<'_>,
        initializer: TokenIndexRange,
        runtime: &[SmolStr],
    ) -> bool {
        (initializer.start()..initializer.end()).any(|index| {
            let TypedToken::Identifier(name) = tokens[index].kind() else {
                return false;
            };
            // A field shares nothing with a global of the same name.
            if tokens
                .previous_non_comment(index)
                .is_some_and(|previous| tokens[previous].kind().is_member_access_operator())
            {
                return false;
            }
            name.starts_with("gl_") || runtime.iter().any(|runtime| runtime == name)
        })
    }

    /// Returns the edits that move one declarator's initializer into its own
    /// function.
    #[expect(
        clippy::single_call_fn,
        reason = "keeps the source edits apart from deciding which globals move"
    )]
    fn wrap_initializer(
        tokens: TokenCursor<'_>,
        declarator: &DeclarationFact,
        qualifiers: Qualifiers,
    ) -> Option<Vec<Fixup>> {
        let initializer = declarator.initializer()?;
        let equals = tokens.previous_non_comment(initializer.start())?;
        let declared = tokens.previous_non_comment(equals)?;
        let semicolon = tokens.top_level_semicolon_from(initializer.start())?;
        let name = declarator.name();

        let mut edits = Vec::new();
        if let Some(constant) = qualifiers.constant {
            let next = tokens.next_non_comment(constant + 1)?;
            edits.push(Fixup::replace(
                SourceSpan::new(tokens[constant].span().start(), tokens[next].span().start())
                    .ok()?,
                "",
            ));
        }
        edits.push(Fixup::insert(
            tokens[declared].span().end_point(),
            format!("; void _we_init_{name}() {{ {name}"),
        ));
        edits.push(Fixup::insert(
            tokens[semicolon].span().end_point(),
            " }".to_owned(),
        ));
        Some(edits)
    }
}

/// Storage and precision qualifiers ahead of a global declaration's type.
#[derive(Clone, Copy)]
struct Qualifiers {
    /// The `const` keyword, when present.
    constant: Option<usize>,
}

impl Qualifiers {
    /// Scans the tokens before `type_index`, or returns `None` for a
    /// qualifier this strategy does not know how to keep.
    #[expect(
        clippy::single_call_fn,
        reason = "constructor keeps qualifier parsing beside the type it fills"
    )]
    fn scan(tokens: TokenCursor<'_>, start: usize, type_index: usize) -> Option<Self> {
        let mut constant = None;
        let mut index = tokens.next_non_comment(start)?;
        while index < type_index {
            match tokens[index].kind() {
                TypedToken::Keyword(KeywordType::Const) => constant = Some(index),
                kind if matches!(kind.source_text(), Some("highp" | "mediump" | "lowp")) => {}
                _ => return None,
            }
            index = tokens.next_non_comment(index + 1)?;
        }
        Some(Self { constant })
    }
}
