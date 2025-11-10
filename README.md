# ДЗ 10, Оптимизация запроса

## Анализ запроса
Проанализируем запрос из тела ролевой функции:
```sql
explain analyze select
	trip_request."InstanceID" as "CardID", -- Ид карточки
	observers."EmployeeID" as "Value", -- Ид сотрудника
	13 as "Type" -- Константа, 13 - тип поля ссылка внутри ДВ
from "dvtable_{51c333e6-a252-4139-a284-dee74127cb87}" trip_request
join "dvtable_city_observers" observers
	on observers."CityID" = trip_request."City"
where trip_request."InstanceID" = ANY('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]);
```

```
"Hash Join  (cost=8.30..447.87 rows=4069 width=36) (actual time=0.420..3.204 rows=6075 loops=1)"
"  Hash Cond: (observers.""CityID"" = trip_request.""City"")"
"  ->  Seq Scan on dvtable_city_observers observers  (cost=0.00..328.00 rows=18900 width=32) (actual time=0.138..1.097 rows=18900 loops=1)"
"  ->  Hash  (cost=8.29..8.29 rows=1 width=32) (actual time=0.146..0.146 rows=1 loops=1)"
"        Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"        ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.124..0.125 rows=1 loops=1)"
"              Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"Planning Time: 1.213 ms"
"Execution Time: 3.495 ms"
```
- Hash Join занимает 61% времени выполнения (включает в себя 34% seq scan)
    - построение хэш-таблицы на основе `tripRequest."City"` (незначительно, всего 0.146 из 3.495 мс)
    - последовательное сканирование каждой строки таблицы `observers` занимает 34% времени выполнения
    - вычисления хэш-кода значения в поле `observers."CityID"` для каждой строки и проверка на наличие первого в хэш-таблице занимают (61 - 34)% ~ 27% времени выполнения

Значит, запрос можно ускорить, избавившись от хэширования и сканирования *всех* строк таблицы `observers`.
Сделать это можно, добавив в `observers` индекс по полю `"CityID"`, так как фильтрация происходит по этому полю.
С этим индексом не нужно будет создавать хэш-таблицу, так как индекс уже отсортирован и СУБД знает, где расположены все нужные строки.
Более того, этот индекс будет содержать все необходимые для фильтрации поля (оно одно - `"CityID"`),
значит, СУБД сможет сделать сканирование *только по индексу* - данные будут считаны прямо из индекса, без обращения к таблице.

## Задача
Добавить в таблицу `observers` индекс по полю `"CityID"`

## Возможные решения
### Изменить первичный ключ (индекс) с ("EmployeeID", "CityID") на ("CityID", "EmployeeID")
Плюсы:
- Сортировка строк производится в первую очередь по `"CityID"`, а уже потом по `"EmployeeID"`, поэтому по-сути у нас будет индекс по `"CityID"`.

Минусы:
- Фильтрация по `"EmployeeID"` станет медленне (сейчас нам это не важно; если станет важно, можно будет добавить индекс);
- При изменении первичного ключа нужно вручную пересоздавать внешние ключи (в нашем случае это не проблема, т.к. другие таблицы не ссылаются на эту таблицу).

### Добавить индекс по CityID
Плюсы:
- Просто и безопасно.

Минусы:
- Накладные расходы, связанные с добавлением нового индекса (когда можно изменить существующий): память на диске, замедление операций записи (insert, update, delete)

## Что делаем
Меняем первичный ключ, потому что:
- не придется создавать новый индекс и нести соответствующие накладные расходы
- нет необходимости пересоздавать внешние ключи, так как на нашу таблицу другие таблицы не ссылаются
- это не прод и у нас есть бэкап, поэтому сломать базу данных и на время сделать таблицу недоступной не страшно. В проде безопаснее добавить индекс.

Код для изменения ПК:
```sql
ALTER TABLE "dvtable_city_observers"
DROP CONSTRAINT dvtable_city_observers_pkey;

ALTER TABLE "dvtable_city_observers"
ADD CONSTRAINT dvtable_city_observers_pkey
PRIMARY KEY ("CityID", "EmployeeID");
```

## Результаты оптимизации
### До 
#### 1
```
"Hash Join  (cost=8.30..447.87 rows=4069 width=36) (actual time=0.420..3.204 rows=6075 loops=1)"
"  Hash Cond: (observers.""CityID"" = trip_request.""City"")"
"  ->  Seq Scan on dvtable_city_observers observers  (cost=0.00..328.00 rows=18900 width=32) (actual time=0.138..1.097 rows=18900 loops=1)"
"  ->  Hash  (cost=8.29..8.29 rows=1 width=32) (actual time=0.146..0.146 rows=1 loops=1)"
"        Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"        ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.124..0.125 rows=1 loops=1)"
"              Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"Planning Time: 1.213 ms"
"Execution Time: 3.495 ms"
```
#### 2
```
"Hash Join  (cost=8.30..447.87 rows=4069 width=36) (actual time=0.036..4.481 rows=6075 loops=1)"
"  Hash Cond: (observers.""CityID"" = trip_request.""City"")"
"  ->  Seq Scan on dvtable_city_observers observers  (cost=0.00..328.00 rows=18900 width=32) (actual time=0.010..1.507 rows=18900 loops=1)"
"  ->  Hash  (cost=8.29..8.29 rows=1 width=32) (actual time=0.019..0.020 rows=1 loops=1)"
"        Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"        ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.016..0.017 rows=1 loops=1)"
"              Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"Planning Time: 0.504 ms"
"Execution Time: 4.729 ms"
```
#### 3
```
"Hash Join  (cost=8.30..447.87 rows=4069 width=36) (actual time=0.034..3.088 rows=6075 loops=1)"
"  Hash Cond: (observers.""CityID"" = trip_request.""City"")"
"  ->  Seq Scan on dvtable_city_observers observers  (cost=0.00..328.00 rows=18900 width=32) (actual time=0.009..1.215 rows=18900 loops=1)"
"  ->  Hash  (cost=8.29..8.29 rows=1 width=32) (actual time=0.019..0.020 rows=1 loops=1)"
"        Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"        ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.017..0.018 rows=1 loops=1)"
"              Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"Planning Time: 0.144 ms"
"Execution Time: 3.276 ms"
```

### После
#### 1
```
"Nested Loop  (cost=0.56..337.83 rows=4069 width=36) (actual time=0.076..1.165 rows=6075 loops=1)"
"  ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.009..0.010 rows=1 loops=1)"
"        Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"  ->  Index Only Scan using dvtable_city_observers_pkey on dvtable_city_observers observers  (cost=0.29..266.54 rows=6300 width=32) (actual time=0.064..0.744 rows=6075 loops=1)"
"        Index Cond: (""CityID"" = trip_request.""City"")"
"        Heap Fetches: 0"
"Planning Time: 0.355 ms"
"Execution Time: 1.345 ms"
```
#### 2
```
"Nested Loop  (cost=0.56..337.83 rows=4069 width=36) (actual time=0.050..0.978 rows=6075 loops=1)"
"  ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.029..0.030 rows=1 loops=1)"
"        Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"  ->  Index Only Scan using dvtable_city_observers_pkey on dvtable_city_observers observers  (cost=0.29..266.54 rows=6300 width=32) (actual time=0.018..0.558 rows=6075 loops=1)"
"        Index Cond: (""CityID"" = trip_request.""City"")"
"        Heap Fetches: 0"
"Planning Time: 0.206 ms"
"Execution Time: 1.164 ms"
```
#### 3
```
"Nested Loop  (cost=0.56..337.83 rows=4069 width=36) (actual time=0.031..0.925 rows=6075 loops=1)"
"  ->  Index Scan using dvsys_carddocument_businesstriprequest_uc_struct on ""dvtable_{51c333e6-a252-4139-a284-dee74127cb87}"" trip_request  (cost=0.28..8.29 rows=1 width=32) (actual time=0.018..0.018 rows=1 loops=1)"
"        Index Cond: (""InstanceID"" = ANY ('{8f25718f-2b21-4d58-b857-a84f627cea5e}'::uuid[]))"
"  ->  Index Only Scan using dvtable_city_observers_pkey on dvtable_city_observers observers  (cost=0.29..266.54 rows=6300 width=32) (actual time=0.011..0.509 rows=6075 loops=1)"
"        Index Cond: (""CityID"" = trip_request.""City"")"
"        Heap Fetches: 0"
"Planning Time: 0.133 ms"
"Execution Time: 1.109 ms"
```
### Выводы
- время выполнения запросов уменьшилось примерно в 3 раза
- вместо дорогостоящих Hash Join и seq scan используются Nested Loop, Index Scan по `trip_request` и Index Only Scan по `observers`.
- мы выиграли время за счет
    - кратного уменьшения количества сканируемых строк
    - избавления от необходимости создавать хэш-таблицу и вычислять хэш-значения для каждой строки
