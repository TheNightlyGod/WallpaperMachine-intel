//! Reads of uniform-block array members widened to `vec4`.

use linkme::distributed_slice;

use super::{
    ARRAY_PARAMETERS, CodegenStage, CodegenStrategy, Emitable, GENERAL_POLICIES, LEGACY_BUILTINS,
    StrategyContext, WIDENED_ARRAYS,
};
use smol_str::SmolStr;

use crate::{
    ShaderResult,
    codegen::{ExpressionReplacement, Fixup, declarations::WidenedArrayMember},
    syntax::SyntaxItem,
    tokenizer::{TokenCursor, TypedToken},
};
/// Object-like `#define NAME VALUE` pairs anywhere in the source.
///
/// Read from the token stream rather than the item list: an audio-bars shader
/// picks its band count with `#define`s written *inside* `main`, which are not
/// module items at all.
fn source_defines(tokens: TokenCursor<'_>) -> Vec<(SmolStr, SmolStr)> {
    let mut defines = Vec::new();
    for index in 0..tokens.len() {
        let TypedToken::Directive(text) = tokens[index].kind() else {
            continue;
        };
        let mut words = text
            .trim_start()
            .trim_start_matches('#')
            .trim_start()
            .split_whitespace();
        if words.next() != Some("define") {
            continue;
        }
        let (Some(name), Some(value), None) = (words.next(), words.next(), words.next()) else {
            continue;
        };
        // Object-like only, and only when the replacement is a bare
        // identifier: `#define F(x)` or an expression names no member.
        if name.contains('(') || !is_identifier(name) || !is_identifier(value) {
            continue;
        }
        defines.push((SmolStr::new(name), SmolStr::new(value)));
    }
    defines
}

/// Returns whether the text is a single GLSL identifier.
fn is_identifier(text: &str) -> bool {
    let mut characters = text.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
        && characters.all(|character| character.is_ascii_alphanumeric() || character == '_')
}

/// Swizzles each indexed read of a widened uniform array back to the type the
/// author declared.
///
/// The declaration is widened because std140 and Metal's natural layout only
/// agree at 16 bytes per element. Every read has to narrow again, or the
/// expression sees a `vec4` where the shader was written for a `float`.
struct WidenedArrayStrategy;

#[distributed_slice(GENERAL_POLICIES)]
static WIDENED_ARRAYS_POLICY: CodegenStrategy = CodegenStrategy {
    name: WIDENED_ARRAYS,
    stage: CodegenStage::SemanticRewrite,
    after: &[LEGACY_BUILTINS, ARRAY_PARAMETERS],
    emitter: &WidenedArrayStrategy,
};

impl Emitable for WidenedArrayStrategy {
    fn emit(&self, context: &mut StrategyContext<'_, '_, '_>) -> ShaderResult<()> {
        let Some(block) = context.context().declarations.uniform_block() else {
            return Ok(());
        };
        let widened = block
            .members
            .iter()
            .filter_map(|member| {
                WidenedArrayMember::classify(member.ty.as_str(), member.array_suffix.as_deref())
                    .map(|widened| (member.name.clone(), widened))
            })
            .collect::<Vec<_>>();
        if widened.is_empty() {
            return Ok(());
        }
        // An audio-bars shader picks its band count with
        // `#define u_AudioSpectrumLeft g_AudioSpectrum16Left` and then reads
        // through the alias, so the identifier in the body never names the
        // member. Every branch of that choice aliases a member widened the
        // same way, which is what makes one swizzle correct for all of them.
        //
        // One definition that does not agree disqualifies the alias for good:
        // whichever branch the preprocessor keeps, a swizzle that is wrong for
        // any of them cannot be applied without knowing which one that is.
        let mut aliases: Vec<(SmolStr, WidenedArrayMember)> = Vec::new();
        let mut disqualified: Vec<SmolStr> = Vec::new();
        for (name, value) in source_defines(context.context().module.token_stream().cursor()) {
            if disqualified.iter().any(|alias| *alias == name) {
                continue;
            }
            let widened = widened
                .iter()
                .find(|(member, _widened)| member.as_str() == value.as_str())
                .map(|(_member, widened)| *widened);
            let position = aliases
                .iter()
                .position(|(alias, _widened)| alias.as_str() == name.as_str());
            match (position, widened) {
                (None, Some(widened)) => aliases.push((name, widened)),
                (Some(at), Some(widened)) if aliases[at].1 == widened => {}
                // A second definition naming a differently widened member.
                (Some(at), _) => {
                    let _removed = aliases.remove(at);
                    disqualified.push(name);
                }
                // A definition naming something not widened. Tombstoned even
                // though there is nothing to remove yet, or the verdict would
                // depend on which branch the author wrote first.
                (None, None) => disqualified.push(name),
            }
        }
        let widened = widened
            .into_iter()
            .chain(aliases)
            .collect::<Vec<_>>();

        let module = context.context().module;
        let tokens = module.token_stream().cursor();
        // Only function bodies. A declaration is subscripted too, and the
        // generated block replaces that statement wholesale, so an insertion
        // inside one would both mean nothing and overlap the replacement.
        let bodies = module
            .items()
            .iter()
            .filter_map(|item| match item {
                SyntaxItem::Function(function) => tokens
                    .contained_byte_range(function.body_span().start(), function.body_span().end()),
                _ => None,
            })
            .collect::<Vec<_>>();
        let mut fixups = Vec::new();
        for body in bodies {
            for index in body.start()..body.end() {
                fixups.extend(Self::narrowing_at(tokens, index, &widened));
            }
        }

        for fixup in fixups {
            context.context().fixups.push(fixup);
        }
        Ok(())
    }
}

impl WidenedArrayStrategy {
    /// Returns the narrowing edit for a widened member read at `index`.
    fn narrowing_at(
        tokens: TokenCursor<'_>,
        index: usize,
        widened: &[(SmolStr, WidenedArrayMember)],
    ) -> Option<Fixup> {
        let TypedToken::Identifier(name) = tokens[index].kind() else {
            return None;
        };
        let (_name, member) = widened
            .iter()
            .find(|(member_name, _widened)| member_name.as_str() == name.as_str())?;
        // A `float` element is a one-component value, as the permissive path
        // treats every scalar, so the only component a further subscript can
        // select is the element itself: `[barID % 4]` reads `.x`. The edit
        // owns the subscript, so fixups inside it go with it.
        if *member == WidenedArrayMember::Scalar
            && let Some(component) = WidenedArrayMember::component_subscript_span(tokens, index)
        {
            return Some(Fixup::replace(
                component,
                ExpressionReplacement::new().with_text(member.swizzle()),
            ));
        }
        let span = WidenedArrayMember::subscript_swizzle_span(tokens, index)?;
        Some(Fixup::insert(span, member.swizzle().to_owned()))
    }
}
