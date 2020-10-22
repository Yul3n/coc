open Combo

type expr
  = Var of string
  | Pi  of string * expr * expr
  | Lam of string * expr option * expr
  | App of expr * expr
  | Deb of int
  | Ann of expr * expr
  | Univ
  | Let of string * expr * expr
[@@deriving show]

type decl
  = TDecl of string * expr
  | FDecl of string * expr

let (%) f g x = f (g x)

let ide =
  inplode <$> many1 letter

let rec expr s =
  let keyword s = word s <* space in
  let lam =
    let lam v t b = Lam (v, t, b) in
        lam 
    <$  keyword "fun"
    <*  spaces
    <*> ide
    <*> (opt None ((fun x -> Some x) <$  between spaces (char ':') spaces
                                     <*> expr))
    <*  between spaces (word "=>") spaces
    <*> expr
  in
  let univ = sym '*' *> return Univ in
  let pi =
    let pi v t b = Pi (v, t, b) in
        pi
    <$  sym '('
    <*  spaces
    <*> ide
    <*  between spaces (char ':') spaces
    <*> expr
    <*  between spaces (word "=>") spaces
    <*> expr
  in
  let var = (fun v -> Var v) <$> ide in
  let letin =
    let letin v e b = Let (v, e, b) in
        letin
    <$  keyword "let"
    <*> ide
    <*  between spaces (char '=') spaces
    <*> expr
    <*  between spaces (keyword "in") spaces
    <*> expr
  in
  let app l r = App (l, r) in
  let arr l r = Pi ("", l, r) in
  let p = (univ <|> lam <|> pi <|> letin <|> var) in
  let p = chainl1 (spaces *> (arr <$ word "->") <* spaces) p
           <|> packs "(" p ")" in
  let app = chainl1 (spaces *> return app <* spaces) p in
  app s

let top_level =
  let tdecl =
    let tdecl s e = TDecl (s, e) in
    tdecl <$> ide <* char ':' <*> expr 
  in
  let fdecl =
    let fdecl s e = FDecl (s, e) in
    fdecl <$> ide <* char '=' <*> expr 
  in
  tdecl <|> fdecl <* char ';'

let rec to_deb e v n =
  match e with
    Var v' when v = v' -> Deb n
  | App (l, r) -> App (to_deb l v n, to_deb r v n)
  | Lam (v', None, b) ->
     Lam ("", None, to_deb (to_deb b v' 0) v (n + 1))
  | Lam (v', Some t, b) ->
     Lam ("", Some (to_deb t v n), to_deb (to_deb b v' 0) v (n + 1))
  | Pi (v', t, b) ->
     Pi ("", to_deb t v n, to_deb (to_deb b v' 0) v (n + 1))
  | Let (v', e, b) -> Let (v', to_deb e v n, to_deb b v n)
  | e -> e

let rec subst e n s =
  match e with
    Deb n' when n' = n -> s
  | App (l, r) -> App (subst l n s, subst r n s)
  | Lam (_, None, b) ->
     Lam ("", None, subst b (n + 1) s)
  | Lam (_, Some t, b) ->
     Lam ("", Some (subst t n s), subst b (n + 1) s)
  | Pi (_, t, b) -> Pi ("", subst t n s, subst b (n + 1) s)
  | Let (v, e, b) -> Let (v, subst e n s, subst b n s)
  | e -> e

let rec reloc e i =
  match e with
    Pi (_, t, b) -> Pi ("", reloc t i, reloc b (i + 1))
  | Lam (_, None, b) -> Lam ("", None, reloc b (i + 1))
  | Lam (_, Some t, b) ->
     Lam ("", Some (reloc t i), reloc b (i + 1))
  | Let (v, e, b) -> Let (v, reloc e i, reloc b i)
  | Deb k when k >= i -> Deb (k + 1)
  | App (l, r) -> App (reloc l i, reloc r i)
  | e -> e

let relocate_ctx =
  List.map (fun e -> reloc e 0)

let rec normalize c g =
  function
    Univ -> Univ
  | Var v ->
     begin 
       match List.assoc_opt v g with
         None -> Var v
       | Some e -> e
     end 
  | App (e, e') ->
     let e' = normalize c g e' in
     (match normalize c g e with
         Lam (_, _, b) -> normalize c g (subst b 0 e')
       | e -> App (e, e'))
  | e -> e

let rec equal c g e e' =
  let e  = normalize c g e in
  let e' = normalize c g e' in
  match e, e' with
    Deb n, Deb n' -> n = n'
  | Var v, Var v' -> v = v'
  | Univ, Univ -> true
  | Lam (_, Some t, b), Lam (_, Some t', b') ->
     equal c g t t' && equal c g b b'
  | Lam (_, None, b), Lam (_, None, b') -> equal c g b b'
  | Ann (e, t), Ann (e', t') ->
     equal c g e e' && equal c g t t'

let rec infer_type (e, exp) c g = 
  match e with
    Deb n -> (List.nth c n)
  | Lam (_, t, b) ->
     (match exp with
       Some (Pi (_, p, p')) ->
        let te = infer_type (b, None) (p :: c) g in
        Pi ("", p, te)
      | None ->
         begin
           match t with
             Some p ->
             let te = infer_type (b, None) (p :: c) g in
             Pi ("", p, te)
           | None -> failwith "missing type annotation."
         end
      | _ -> failwith "bad type for lambda abstraction.")
  | Univ -> Univ
  | Pi (_, p, p') ->
     infer_universe c g p;
     infer_universe (p :: c) g p';
     Univ
  | Var v -> List.assoc v g
  | Let (v, t, b) ->
     let t = infer_type t c g in
     infer_type b c ((v, t) :: g)
  | App (l, r) ->
     let t = infer_type l c g in
     match t with
       Pi (_, t, t') ->
       check r t c g;
       subst t' 0 r
     | _ -> failwith "Type error"

and check e t c g =
    let t' = infer_type (e, None) c g in
    if t = t'
    then ()
    else failwith "Type error"

and infer_universe c g e =
  let u = infer_type (e, None) c g  in
  match normalize c g u with
    Univ -> () 
  | _ -> failwith "expected type"

let _ =
  let e = expr (explode (read_line ())) in
  match e with
    None -> failwith "Syntax error"
  | Some (e, _) -> (print_endline %
                      show_expr %
                        (fun x -> infer_type x [] []) %
                          (fun x -> to_deb x "" 0, None))
                     e
