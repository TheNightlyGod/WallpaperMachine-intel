//! Declarator lists whose array suffix would leak into later declarators.
//!
//! In GLSL an array suffix belongs to one declarator: `float color[4], f;`
//! declares an array and a scalar. Naga's GLSL frontend applies the suffix to
//! the type it shares with the rest of the list, so `f` becomes `float[4]`
//! and every use of it fails validation. Ending the declaration after each
//! array declarator and restating the qualifiers and type for the rest gives
//! naga one suffix per statement.

use linkme::distributed_slice;

use super::{
    ARRAY_DECLARATORS, CodegenStage, CodegenStrategy, Emitable, GENERAL_POLICIES, StrategyContext,
};
use crate::{
    ShaderResult,
    codegen::{Fixup, declarations::LegacyTypeName},
    tokenizer::{DeclarationFact, TokenCursor, TypedToken},
};

/// Splits declarator lists after every declarator with an array suffix.
struct ArrayDeclaratorsStrategy;

#[distributed_slice(GENERAL_POLICIES)]
static ARRAY_DECLARATORS_POLICY: CodegenStrategy = CodegenStrategy {
    name: ARRAY_DECLARATORS,
    stage: CodegenStage::SemanticRewrite,
    after: &[],
    emitter: &ArrayDeclaratorsStrategy,
};

impl Emitable for ArrayDeclaratorsStrategy {
    fn emit(&self, context: &mut StrategyContext<'_, '_, '_>) -> ShaderResult<()> {
        let module = context.context().module;
        let tokens = module.token_stream().cursor();
        let declarations = module.token_facts().declarations();
        let mut fixups = Vec::new();
        for declarator in declarations {
            let separator = declarator.declarator().end().saturating_sub(1);
            if !matches!(tokens[separator].kind(), TypedToken::Comma)
                || !tokens
                    .next_non_comment(declarator.name_index() + 1)
                    .is_some_and(|next| tokens[next].kind().is_left_square())
            {
                continue;
            }
            let Some(prefix) = restated_prefix(tokens, declarator) else {
                continue;
            };
            fixups.push(Fixup::replace(tokens[separator].span(), format!("; {prefix} ")));
        }
        let context = context.context();
        for fixup in fixups {
            context.fixups.push(fixup);
        }
        Ok(())
    }
}

/// Returns the qualifiers and type that begin the next statement of a split
/// list, or `None` when the list must stay whole.
///
/// A `for` initializer cannot hold two statements, and stage interface or
/// uniform declarations are emitted one name at a time by the declaration
/// planner, so neither reaches naga as a list.
#[expect(
    clippy::single_call_fn,
    reason = "keeps the eligibility rules apart from the source edit"
)]
fn restated_prefix(tokens: TokenCursor<'_>, declarator: &DeclarationFact) -> Option<String> {
    let statement = declarator.statement();
    if tokens.enclosing_left_paren_before(statement.start()).is_some() {
        return None;
    }
    let mut prefix = Vec::new();
    let mut index = tokens.next_non_comment(statement.start())?;
    while index < declarator.type_index() {
        let kind = tokens[index].kind();
        if !kind.is_declaration_modifier() {
            return None;
        }
        prefix.push(kind.source_text()?);
        index = tokens.next_non_comment(index + 1)?;
    }
    prefix.push(LegacyTypeName::new(declarator.ty().as_str()).glsl());
    Some(prefix.join(" "))
}
