CREATE OR REPLACE FUNCTION PUBLIC."dd_school_city_observers" (val_cardids UUID[])
RETURNS TABLE ("CardID" UUID, "Value" UUID, "Type" INTEGER)
AS $function$
begin
	return query
	select
		tripRequest."InstanceID" as "CardID", -- Ид карточки
		observers."EmployeeID" as "Value", -- Ид сотрудника
		13 as "Type" -- Константа, 13 - тип поля ссылка внутри ДВ
	from "dvtable_{51c333e6-a252-4139-a284-dee74127cb87}" tripRequest
	join "dvtable_city_observers" observers
		on observers."CityID" = tripRequest."City"
	where tripRequest."InstanceID" = ANY(val_cardids);
end;
$function$
LANGUAGE PLPGSQL;