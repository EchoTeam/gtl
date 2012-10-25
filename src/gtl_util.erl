-module(gtl_util).
-export([
    time_to_string/2,
    now2micro/1,
    now2string/1
]).

int_to_wd(1) -> "Mon";
int_to_wd(2) -> "Tue";
int_to_wd(3) -> "Wed";
int_to_wd(4) -> "Thu";
int_to_wd(5) -> "Fri";
int_to_wd(6) -> "Sat";
int_to_wd(7) -> "Sun".

month(1) -> "Jan";
month(2) -> "Feb";
month(3) -> "Mar";
month(4) -> "Apr";
month(5) -> "May";
month(6) -> "Jun";
month(7) -> "Jul";
month(8) -> "Aug";
month(9) -> "Sep";
month(10) -> "Oct";
month(11) -> "Nov";
month(12) -> "Dec".

time_to_string({{Year, Month, Day}, {Hour, Min, Sec}}, Zone) ->
    io_lib:format("~s, ~s ~s ~w ~s:~s:~s ~s",
        [int_to_wd(calendar:day_of_the_week(Year, Month, Day)),
        mk2(Day), month(Month), Year,
        mk2(Hour), mk2(Min), mk2(Sec), Zone]).

mk2(A) when A >= 100 -> integer_to_list(A rem 100);
mk2(A) when A >= 10  -> integer_to_list(A);
mk2(A) -> "0" ++ integer_to_list(A).

now2string(Now) ->
    {{Y,M,D},{H,Min,S}} = calendar:now_to_local_time(Now),
    integer_to_list(Y) ++ "/" ++ mk2(M) ++ "/" ++ mk2(D) ++
        " " ++ mk2(H) ++ ":" ++ mk2(Min) ++ ":" ++ mk2(S).

now2micro({Mega, Sec, Micro}) -> Mega * 1000000000000 + Sec * 1000000 + Micro.
