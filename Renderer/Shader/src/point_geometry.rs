//! Point-input geometry programs lowered to the vertex stage supplied by the renderer.
//!
//! The shader body remains ordinary author code. Only the geometry interface and its
//! output stream are adapted; dialect validation still happens after this rewrite.

mod rewrite;

use std::collections::{HashMap, HashSet};
use crate::dialect::{self, ast::*, print, ty::{builtin_type, Sc, Ty}};
use crate::lexer::{lex, Operator, Token, TokenStream};
use crate::request::{PointGeometry, StageKind};

const POSITION: &str = "wm_geometry_position";

type Fields = Vec<(String, TypeRef)>;

fn parsed(text: &str) -> Result<Module, String> {
    dialect::parse_stage(StageKind::Vertex, text).map(|(module, _)| module)
        .map_err(|errors| format!("point geometry syntax: {errors:?}"))
}

fn integer(e: &Expr, constants: &HashMap<String, i64>) -> Option<i64> {
    match &e.kind {
        ExprKind::Number(value) => value.trim_end_matches(['u', 'U']).parse().ok(),
        ExprKind::Ident(name) => constants.get(name).copied(),
        ExprKind::Paren(value) => integer(value, constants),
        ExprKind::Unary(Operator::Add, value) => integer(value, constants),
        ExprKind::Unary(Operator::Sub, value) => integer(value, constants)?.checked_neg(),
        ExprKind::Binary(op, a, b) => {
            let (a, b) = (integer(a, constants)?, integer(b, constants)?);
            match op {
                Operator::Add => a.checked_add(b), Operator::Sub => a.checked_sub(b),
                Operator::Mul => a.checked_mul(b), Operator::Div => a.checked_div(b),
                Operator::Mod => a.checked_rem(b),
                _ => None,
            }
        }
        _ => None,
    }
}

/// The attribute is a language construct, found in expanded tokens, never by file name.
fn geometry_module(source: &str, expected: u32) -> Result<Module, String> {
    let expanded = dialect::expand::expand(&lex(source))
        .map_err(|error| format!("point geometry macros: {}", error.message))?;
    let stream = TokenStream::from(expanded);
    let mut kept: Vec<Token> = Vec::new();
    let mut bound = None;
    let mut index = 0;
    while index < stream.len() {
        if stream[index].is_left_bracket() && stream.get(index + 1).is_some_and(|token| token.text == "maxvertexcount") {
            let end = stream.matching_close(index).ok_or("unclosed maxvertexcount attribute")?;
            if bound.is_some() || !stream.get(index + 2).is_some_and(Token::is_left_paren)
                || !stream.get(end.wrapping_sub(1)).is_some_and(Token::is_right_paren) {
                return Err("point geometry needs one maxvertexcount expression".into());
            }
            let expression = stream[index + 3..end - 1].iter().map(|token| token.text.as_str()).collect::<Vec<_>>().join(" ");
            let temp = parsed(&format!("const int wm_bound = {expression};"))?;
            let Some(Item::Var(decl)) = temp.items.first() else { return Err("invalid geometry output bound".into()) };
            bound = decl.declarators[0].init.clone();
            if !stream.get(end + 1).is_some_and(|token| token.text == "void")
                || !stream.get(end + 2).is_some_and(|token| token.text == "main") {
                return Err("maxvertexcount must describe the point geometry main entry".into());
            }
            index = end + 1;
        } else {
            kept.push(stream[index].clone());
            index += 1;
        }
    }
    let module = dialect::parse::parse(&kept).map_err(|error| format!("point geometry syntax: {}", error.message))?;
    let mut constants = HashMap::new();
    for item in &module.items {
        if let Item::Var(decl) = item {
            if decl.has_word("const") {
                for variable in &decl.declarators {
                    if let Some(value) = variable.init.as_ref().and_then(|e| integer(e, &constants)) {
                        constants.insert(variable.name.clone(), value);
                    }
                }
            }
        }
    }
    let actual = bound.as_ref().and_then(|e| integer(e, &constants))
        .ok_or("point geometry requires a constant maxvertexcount on main")?;
    if actual != i64::from(expected) {
        return Err(format!("point geometry declares {actual} output vertices, caller requested {expected}"));
    }
    Ok(module)
}

fn interface(module: &Module, qualifiers: &[&str]) -> Result<Fields, String> {
    let mut fields = Vec::new();
    for item in &module.items {
        if let Item::Var(decl) = item {
            if !qualifiers.iter().any(|word| decl.has_word(word)) { continue; }
            for variable in &decl.declarators {
                if !decl.ty.dims.is_empty() || !variable.dims.is_empty()
                    || !matches!(builtin_type(&decl.ty.name), Some(Ty::Scalar(_) | Ty::Vec(..) | Ty::Mat(..))) {
                    return Err(format!("point geometry interface `{}` must be a numeric scalar, vector, or matrix", variable.name));
                }
                if fields.iter().any(|(name, _)| name == &variable.name) {
                    return Err(format!("duplicate point geometry interface `{}`", variable.name));
                }
                fields.push((variable.name.clone(), decl.ty.clone()));
            }
        }
        if let Item::Block(block) = item {
            if qualifiers.iter().any(|word| block.quals.iter().any(|q| q.is_word(word))) {
                return Err("point geometry interface blocks are not supported".into());
            }
        }
    }
    Ok(fields)
}

fn field(name: &str) -> &str { if name == "gl_Position" { POSITION } else { name } }

fn structure(name: &str, fields: &Fields) -> String {
    let mut result = format!("struct {name} {{\n");
    for (name, ty) in fields { result.push_str(&format!("{} {};\n", ty.name, field(name))); }
    result.push_str("};\n"); result
}

fn zero(ty: &TypeRef) -> String {
    let literal = |kind: Sc| if kind == Sc::Bool { "false" } else if kind == Sc::Uint { "0u" } else { "0" };
    match builtin_type(&ty.name).expect("numeric interface validated") {
        Ty::Scalar(kind) => literal(kind).into(),
        Ty::Vec(kind, width) => format!("{}({})", ty.name, vec![literal(kind); usize::from(width)].join(", ")),
        Ty::Mat(columns, rows) => format!("{}({})", ty.name, vec!["0"; usize::from(columns) * usize::from(rows)].join(", ")),
        _ => unreachable!("numeric interface validated"),
    }
}

struct Names { taken: HashSet<String> }
impl Names {
    fn new(vertex: &str, geometry: &str) -> Self {
        Self { taken: lex(vertex).iter().chain(lex(geometry).iter()).filter(|token| token.is_name_like()).map(|token| token.text.clone()).collect() }
    }
    fn fresh(&mut self, base: &str) -> String {
        let candidate = format!("wm_geometry_{base}");
        if self.taken.insert(candidate.clone()) { return candidate; }
        for i in 1.. { let next = format!("{candidate}_{i}"); if self.taken.insert(next.clone()) { return next; } }
        unreachable!()
    }
}

pub(crate) fn lower(vertex_source: &str, geometry_source: &str, descriptor: &PointGeometry) -> Result<String, String> {
    let mut vertex = parsed(vertex_source)?;
    let mut geometry = geometry_module(geometry_source, descriptor.max_vertices)?;
    let mut input = interface(&vertex, &["varying", "out"])?;
    if !input.iter().any(|(name, _)| name == "gl_Position") {
        input.push(("gl_Position".into(), TypeRef::named("vec4")));
    }
    let declared_inputs = interface(&geometry, &["in"])?;
    for (name, ty) in &declared_inputs {
        let Some((_, produced)) = input.iter().find(|(n, _)| n == name) else { return Err(format!("geometry input `{name}` is not produced by the vertex stage")) };
        if builtin_type(&ty.name) != builtin_type(&produced.name) {
            return Err(format!("geometry input `{name}` has a different type from the vertex output"));
        }
    }
    let output = interface(&geometry, &["out"])?;
    if !output.iter().any(|(name, ty)| name == "gl_Position" && builtin_type(&ty.name) == Some(Ty::vec(4))) {
        return Err("point geometry must declare an output vec4 gl_Position".into());
    }
    let mut names = Names::new(vertex_source, geometry_source);
    if names.taken.contains(&descriptor.output_index_attribute) {
        return Err("point geometry output-index attribute collides with an author identifier".into());
    }
    names.taken.insert(descriptor.output_index_attribute.clone());
    let input_type = names.fresh("Input"); let output_type = names.fresh("Output");
    let input_array = names.fresh("input"); let selected = names.fresh("selected");
    let wanted = names.fresh("wanted"); let count = names.fresh("count"); let found = names.fresh("found");
    let emit = names.fresh("append"); let vertex_entry = names.fresh("vertex"); let geometry_entry = names.fresh("entry");
    let mut vertex_names = HashMap::new();
    for (name, _) in &input { vertex_names.insert(name.clone(), names.fresh(&format!("vs_{name}"))); }
    vertex_names.insert("main".into(), vertex_entry.clone());
    let mut geometry_names = HashMap::new();
    let mut type_names = HashMap::new();
    type_names.insert("PS_INPUT".into(), output_type.clone());
    geometry_names.insert("main".into(), geometry_entry.clone());
    geometry_names.insert("IN".into(), input_array.clone());
    for item in &geometry.items {
        match item {
            Item::Function(function) if function.name != "main" => {
                geometry_names.entry(function.name.clone()).or_insert_with(|| names.fresh(&format!("gs_{}", function.name)));
            }
            Item::Var(decl) if !decl.has_word("uniform") => for variable in &decl.declarators {
                geometry_names.entry(variable.name.clone()).or_insert_with(|| names.fresh(&format!("gs_{}", variable.name)));
            },
            Item::Struct(definition) => if let Some(name) = &definition.name {
                if name == "PS_INPUT" { return Err("PS_INPUT is the implicit geometry output record".into()); }
                type_names.insert(name.clone(), names.fresh(&format!("gs_{name}")));
            },
            _ => {}
        }
    }
    // Both entries must be real void main() functions, not macros or declarations.
    for (module, label) in [(&vertex, "vertex"), (&geometry, "geometry")] {
        let entries: Vec<_> = module.items.iter().filter_map(|item| match item { Item::Function(f) if f.name == "main" && f.body.is_some() => Some(f), _ => None }).collect();
        if entries.len() != 1 || entries[0].ret.name != "void" || !entries[0].params.is_empty() {
            return Err(format!("point {label} stage needs exactly one void main() entry"));
        }
    }
    let position_declared = vertex.items.iter().any(|item| matches!(item, Item::Var(decl) if decl.declarators.iter().any(|v| v.name == "gl_Position")));
    for item in &mut vertex.items {
        if let Item::Var(decl) = item { decl.quals.retain(|q| !q.is_word("varying") && !q.is_word("out")); }
    }
    // Geometry declarations describe implicit input/output records; keep private globals
    // for direct output writes, but expose only the selected record to the fragment stage.
    geometry.items.retain(|item| !matches!(item, Item::Var(decl) if decl.has_word("in")));
    for item in &mut geometry.items {
        if let Item::Var(decl) = item { decl.quals.retain(|q| !q.is_word("out")); }
    }
    rewrite::module(&mut vertex, &vertex_names, &HashMap::new(), None)?;
    rewrite::module(&mut geometry, &geometry_names, &type_names, Some((&emit, &input_array)))?;

    let mut text = structure(&input_type, &input);
    text.push_str(&structure(&output_type, &output));
    text.push_str(&format!("{input_type} {input_array}[1];\n{output_type} {selected};\nint {wanted};\nint {count};\nbool {found};\nattribute vec4 {};\n", descriptor.output_index_attribute));
    if !position_declared { text.push_str(&format!("vec4 {};\n", vertex_names["gl_Position"])); }
    for (name, ty) in &output {
        if name != "gl_Position" { text.push_str(&format!("varying {} {};\n", ty.name, name)); }
    }
    text.push_str(&format!("void {emit}({output_type} value) {{\nif ({count} < {} && !{found}) {{ {selected} = value; }}\nif ({count} == {wanted}) {{ {found} = true; }}\n{count}++;\n}}\n", descriptor.max_vertices));
    text.push_str(&print::module_to_string(&vertex));
    // Shared uniform names retain a single compatible declaration. Other geometry
    // globals/helpers have stage-private names, so distinct definitions remain distinct.
    let mut uniforms: HashMap<String, Ty> = HashMap::new();
    for item in &vertex.items {
        if let Item::Var(decl) = item { if decl.has_word("uniform") {
            for variable in &decl.declarators { if let Some(ty) = builtin_type(&decl.ty.name) { uniforms.insert(variable.name.clone(), ty); } }
        }}
    }
    for item in geometry.items {
        if let Item::Var(mut decl) = item {
            if decl.has_word("uniform") {
                let ty = builtin_type(&decl.ty.name);
                let mut kept = Vec::new();
                for variable in decl.declarators {
                    if let Some(previous) = uniforms.get(&variable.name) {
                        if Some(previous) != ty.as_ref() { return Err(format!("conflicting geometry uniform `{}`", variable.name)); }
                    } else {
                        if let Some(ty) = &ty { uniforms.insert(variable.name.clone(), ty.clone()); }
                        kept.push(variable);
                    }
                }
                decl.declarators = kept;
                if decl.declarators.is_empty() { continue; }
            }
            print::write_item(&mut text, &Item::Var(decl));
        } else { print::write_item(&mut text, &item); }
    }
    text.push_str(&format!("void main() {{\n{vertex_entry}();\n"));
    for (name, _) in &input { text.push_str(&format!("{input_array}[0].{} = {};\n", field(name), vertex_names[name])); }
    text.push_str(&format!("{wanted} = clamp(int({}.x), 0, {});\n{count} = 0;\n{found} = false;\n", descriptor.output_index_attribute, descriptor.max_vertices - 1));
    for (name, ty) in &output { text.push_str(&format!("{selected}.{} = {};\n", field(name), if name == "gl_Position" { "vec4(0, 0, 0, 1)".into() } else { zero(ty) })); }
    text.push_str(&format!("{geometry_entry}();\n"));
    for (name, _) in &output { text.push_str(&format!("{name} = {selected}.{};\n", field(name))); }
    text.push_str("}\n");
    Ok(text)
}
