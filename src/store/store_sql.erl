-module(store_sql).
-author('Daniil Churikov').
-license("MIT").
-compile(export_all).
-include("sql.hrl").
-include("metainfo.hrl").

insert(E, Table, S) ->
    SkipFun = fun(#column{ro = RO}, V) -> RO orelse V == '$skip' end,
    Q = prepare_insert(skip(SkipFun, Table#table.columns, e2l(E)), Table, S),
    if Q#query.values /= [] -> {ok, build(Q)};
    true -> {error, empty_insert} end.

select_pk(E, Table, S) ->
    SkipFun = fun(#column{key = Key}, _) -> not Key end,
    Q = prepare_select(skip(SkipFun, Table#table.columns, e2l(E)), Table, S),
    if Q#query.values /= [] -> {ok, build(Q)};
    true -> {error, pk_miss} end.

select(E, Table, S) ->
    SkipFun = fun(_, V) -> V == '$skip' end,
    {ok, build(prepare_select(skip(SkipFun, Table#table.columns, e2l(E)), Table, S))}.

update_pk(E, Table = #table{columns = MekaoCols}, S) ->
    SetSkipFun = fun(#column{ro = RO}, V) -> RO orelse V == '$skip' end,
    WhereSkipFun = fun(#column{key = Key}, _) -> not Key end,
    Vals = e2l(E),
    Q = prepare_update(skip(SetSkipFun, MekaoCols, Vals),
                       skip(WhereSkipFun, MekaoCols, Vals),Table, S),
    if (Q#query.body)#sql_update.set == [] -> {error, empty_update};
       (Q#query.body)#sql_update.where == [] -> {error, pk_miss};
       true -> {ok, build(Q)} end.

update_pk_diff(E1, E2, Table = #table{columns = MekaoCols}, S) ->
    Vals1 = e2l(E1),
    Vals2 = e2l(E2),
    DiffVals = map2(
        fun (V, V) -> '$skip';
            (_, V2) -> V2 end, Vals1, Vals2),
    SetSkipFun = fun(#column{ro = RO}, V) -> RO orelse V == '$skip' end,
    WhereSkipFun = fun(#column{key = Key}, _) -> not Key end,
    Q = prepare_update(skip(SetSkipFun, MekaoCols, DiffVals),
                       skip(WhereSkipFun, MekaoCols, Vals1),Table, S),
    if (Q#query.body)#sql_update.set == [] -> {error, empty_update};
       (Q#query.body)#sql_update.where == [] -> {error, pk_miss};
       true -> {ok, build(Q)} end.

update(E, Selector, Table = #table{columns = MekaoCols}, S) ->
    SetSkipFun = fun(#column{ro = RO}, V) -> RO orelse V == '$skip' end,
    WhereSkipFun = fun(_, V) -> V == '$skip' end,
    Q = prepare_update(skip(SetSkipFun, MekaoCols, e2l(E)),
                       skip(WhereSkipFun, MekaoCols, e2l(Selector)),Table, S),
    if (Q#query.body)#sql_update.set == [] -> {error, empty_update};
       true -> {ok, build(Q)} end.

delete_pk(E, Table, S) ->
    SkipFun = fun(#column{key = Key}, _) -> not Key end,
    Q = prepare_delete(skip(SkipFun, Table#table.columns, e2l(E)), Table, S),
    if Q#query.values /= [] -> {ok, build(Q)};
       true -> {error, pk_miss} end.

delete(Selector, Table, S) ->
    SkipFun = fun(_, V) -> V == '$skip' end,
    Q = prepare_delete(skip(SkipFun, Table#table.columns, e2l(Selector)), Table, S),
    {ok, build(Q)}.

prepare_insert(E, Table, S) ->
    {Cols, PHs, Types, Vals} = qdata(1, e2l(E), Table#table.columns, S),
    Q = #sql_insert{table=Table#table.name,columns=intersperse(Cols, <<", ">>),
                   values=intersperse(PHs, <<", ">>),returning=returning(insert, Table, S)},
    #query{body=Q,types=Types,values=Vals,next_ph_num=length(PHs) + 1}.

prepare_select(E, Table, S) ->
    #table{columns = MekaoCols,order_by = OrderBy} = Table,
    {Where, {_, PHs, Types, Vals}} = where(qdata(1, e2l(E), MekaoCols, S), S),
    AllCols = intersperse(MekaoCols, <<", ">>, fun(#column{name = Name}) -> Name end),
    Q = #sql_select{table=Table#table.name,columns=AllCols,where=Where,order_by=order_by(OrderBy)},
    #query{body=Q,types=Types,values=Vals,next_ph_num = length(PHs) + 1}.

prepare_update(SetE, WhereE, Table = #table{columns = MekaoCols}, S) ->
    {SetCols, SetPHs, SetTypes, SetVals} = qdata(1, e2l(SetE), MekaoCols, S),
    SetPHsLen = length(SetPHs),
    {Where, {_, WherePHs, WhereTypes, WhereVals}} = where(qdata(SetPHsLen + 1, e2l(WhereE), MekaoCols, S), S),
    WherePHsLen = length(WherePHs),
    Set = intersperse2(fun (C, PH) -> [C, <<" = ">>, PH] end,<<", ">>, SetCols, SetPHs),
    Q = #sql_update{table=Table#table.name,set=Set,where=Where,returning=returning(update, Table, S)},
    #query{body=Q,types=SetTypes++WhereTypes,values=SetVals++WhereVals,next_ph_num = SetPHsLen + WherePHsLen + 1}.

prepare_delete(E, Table, S) ->
    {Where, {_, PHs, Types, Vals}} = where(qdata(1, e2l(E), Table#table.columns, S), S),
    Q = #sql_delete{table=Table#table.name,where=Where,returning=returning(delete, Table, S)},
    #query{body=Q,types=Types,values=Vals,next_ph_num = length(PHs) + 1}.

build(Q = #query{body = Select}) when is_record(Select, sql_select) ->
    #sql_select{columns=Columns,table=Table,where=Where,order_by=OrderBy} = Select,
    Q#query{body = [<<"SELECT ">>, Columns, <<" FROM ">>, Table, build_where(Where),build_order_by(OrderBy)]};
build(Q = #query{body = Insert}) when is_record(Insert, sql_insert) ->
    #sql_insert{table=Table,columns=Columns,values=Values,returning=Return} = Insert,
    Q#query{body = [<<"INSERT INTO ">>, Table, <<" (">>, Columns, <<") VALUES (">>,Values, <<")">>, build_return(Return)]};
build(Q = #query{body = Update}) when is_record(Update, sql_update) ->
    #sql_update{table=Table,set=Set,where=Where,returning=Return} = Update,
    Q#query{body = [<<"UPDATE ">>, Table, <<" SET ">>, Set,build_where(Where), build_return(Return)]};
build(Q = #query{body = Delete}) when is_record(Delete, sql_delete) ->
    #sql_delete{table=Table,where=Where,returning=Return} = Delete,
    Q#query{body = [<<"DELETE FROM ">>, Table, build_where(Where),build_return(Return)]}.

e2l(Vals) when is_list(Vals) -> Vals;
e2l(E) when is_tuple(E) -> [_EntityName | Vals] = tuple_to_list(E), Vals.

skip(SkipFun, Cols, Vals) -> map2(fun(C, V) -> Skip = SkipFun(C, V),if Skip -> '$skip'; true -> V end end, Cols, Vals).

qdata(_, [], [], _) -> {[], [], [], []};
qdata(Num, ['$skip' | Vals], [_Col | Cols], S) -> qdata(Num, Vals, Cols, S);
qdata(Num, [Pred | Vals], [Col | Cols], S) ->
    #column{type = T, name = CName, transform = TrFun} = Col,
    V = predicate_val(Pred),
    NewV = if TrFun == undefined -> V;
                            true -> TrFun(V) end,
    PH = (S#sql_settings.placeholder)(Col, Num, NewV),
    NewPred = set_predicate_val(Pred, NewV), {ResCols, ResPHs, ResTypes, ResVals} = qdata(Num + 1, Vals, Cols, S),
    {[CName | ResCols], [PH | ResPHs], [T | ResTypes], [NewPred | ResVals]}.

returning(_QType, _Table, #sql_settings{returning = undefined}) -> [];
returning(QType, Table, #sql_settings{returning = RetFun}) -> RetFun(QType, Table).

where(QData = {[], [], [], []}, _S) -> {[], QData};
where({[C], [PH], [T], [V]}, S) ->
    {W, {NewC, NewPH, NewT, NewV}} = predicate({C, PH, T, V}, S),
    {[W], {[NewC], [NewPH], [NewT], [NewV]}};
where({[C | Cs], [PH | PHs], [T | Types], [V | Vals]}, S) ->
    {W, {NewC, NewPH, NewT, NewV}} = predicate({C, PH, T, V}, S),
    {Ws, {NewCs, NewPHs, NewTypes, NewVals}} = where({Cs, PHs, Types, Vals}, S),
    {[W, <<" AND ">> | Ws], {[NewC | NewCs], [NewPH | NewPHs], [NewT | NewTypes], [NewV | NewVals]}}.

%% TODO: add NOT, IN, ANY, ALL, BETWEEN, LIKE handling
predicate({C, PH, T, {'$predicate', Op, V}}, S) when Op == '='; Op == '<>' ->
    IsNull = (S#sql_settings.is_null)(V),
    if not IsNull -> {[C, op_to_bin(Op), PH], {C, PH, T, V}};
    Op == '=' -> {[C, <<" IS NULL">>], {C, PH, T, V}};
    Op == '<>' -> {[C, <<" IS NOT NULL">>], {C, PH, T, V}} end;
predicate({C, PH, T, {'$predicate', OP, V}},  _S) -> {[C, op_to_bin(OP), PH],  {C, PH, T, V}};
predicate({C, PH, T, V}, S) -> predicate({C, PH, T, {'$predicate', '=', V}}, S).

op_to_bin('=')  -> <<" = ">>;
op_to_bin('<>') -> <<" <> ">>;
op_to_bin('>')  -> <<" > ">>;
op_to_bin('>=') -> <<" >= ">>;
op_to_bin('<')  -> <<" < ">>;
op_to_bin('<=') -> <<" <= ">>.

order_by([]) -> [];
order_by([O]) -> [order_by_1(O)];
order_by([O | OrderBy]) -> [order_by_1(O), <<", ">> | order_by(OrderBy)].
order_by_1(E) when not is_tuple(E) -> order_by_1({E, {default, default}});
order_by_1({Pos, Opts}) when is_integer(Pos) -> order_by_1({integer_to_list(Pos - 1), Opts});
order_by_1({Expr, Opts}) when is_list(Expr); is_binary(Expr) -> [Expr, order_by_opts(Opts)].
order_by_opts({Ordering, Nulls}) ->
    O = case Ordering of
        default -> <<"">>;
        asc -> <<" ASC">>;
        desc -> <<" DESC">> end,
    case Nulls of
        default -> O;
        nulls_first -> <<O/binary," NULLS FIRST">>;
        nulls_last -> <<O/binary, " NULLS LAST">> end.

build_return([]) -> <<>>;
build_return(Return) -> [<<" ">> | Return].
build_where([]) -> <<>>;
build_where(Where) -> [<<" WHERE ">> | Where].
build_order_by([]) -> <<>>;
build_order_by(OrderBy) -> [<<" ORDER BY ">>, OrderBy].

predicate_val({'$predicate', _, V}) -> V;
predicate_val(V) -> V.

set_predicate_val({'$predicate', Op, _}, NewV) -> {'$predicate', Op, NewV};
set_predicate_val(_, NewV) -> NewV.

map2(_Fun, [], []) -> [];
map2(Fun, [V1 | L1], [V2 | L2]) -> [Fun(V1, V2) | map2(Fun, L1, L2)].

intersperse(List, Sep) -> intersperse(List, Sep, fun (X) -> X end).
intersperse([], _, _) -> [];
intersperse([Item], _, Fun) -> [Fun(Item)];
intersperse([Item | Items], Sep, Fun) -> [Fun(Item), Sep | intersperse(Items, Sep, Fun)].

intersperse2(_Fun, _Sep, [], []) -> [];
intersperse2(Fun, _Sep, [I1], [I2]) -> [Fun(I1, I2)];
intersperse2(Fun, Sep, [I1 | I1s], [I2 | I2s]) -> [Fun(I1, I2), Sep | intersperse2(Fun, Sep, I1s, I2s)].
