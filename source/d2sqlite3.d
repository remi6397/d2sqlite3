// Written in the D programming language
/++
This module provides a simple "object-oriented" interface to the SQLite database engine.
See example in the documentation for the Database struct below. The (hopefully) complete C
API is available through the $(D sqlite3) module, which is publicly imported by this module.

Copyright:
    Copyright Nicolas Sicard, 2011-2014.

License:
    $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors:
    Nicolas Sicard (dransic@gmail.com).

Macros:
    D = <tt>$0</tt>
    DK = <strong><tt>$0</tt></strong>
+/
module d2sqlite3;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.range;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;
import std.variant;
import std.c.string : memcpy;
public import sqlite3;

debug import std.stdio;


/++
Metadata from the SQLite library.
+/
struct Sqlite3
{
    /++
    Gets the library's version string (e.g. "3.8.7").
    +/
    static @property string versionString() nothrow
    {
        return to!string(sqlite3_libversion());
    }

    /++
    Gets the library's version number (e.g. 3008007).
    +/
    static @property int versionNumber() nothrow
    {
        return sqlite3_libversion_number();
    }
}


/++
A caracteristic of user-defined functions or aggregates.
+/
enum Deterministic
{
    /++
    The returned value is the same if the function is called with the same parameters.
    +/
    yes = 0x800,

    /++
    The returned value can vary even if the function is called with the same parameters.
    +/
    no = 0
}


/++
An SQLite database connection.

This struct is a reference-counted wrapper around a $(D sqlite3*) pointer.
+/
struct Database
{
private:
    struct _Core
    {
        sqlite3* handle;

        this(sqlite3* handle) @safe pure nothrow
        {
            this.handle = handle;
        }

        ~this()
        {
            if (handle)
            {
                auto result = sqlite3_close(handle);
                enforce(result == SQLITE_OK, new SqliteException(errmsg(handle), result));
            }
            handle = null;
        }

        @disable this(this);
        void opAssign(_Core) { assert(false); }
    }

    alias RefCounted!(_Core, RefCountedAutoInitialize.no) Core;
    Core core;

public:
    /++
    Opens a database connection.

    Params:
        path = The path to the database file. In recent versions of SQLite, the path can be
        an URI with options.

        flags = Options flags.

    See_Also: $(LINK http://www.sqlite.org/c3ref/open.html) to know how to use the flags
    parameter or to use path as a file URI if the current configuration allows it.
    +/
    this(string path, int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    {
        sqlite3* hdl;
        auto result = sqlite3_open_v2(cast(char*) path.toStringz, &hdl, flags, null);
        core = Core(hdl);
        enforce(result == SQLITE_OK,
                new SqliteException(core.handle
                            ? errmsg(core.handle)
                            : "Error opening the database", result));
    }

    /++
    Gets the SQLite internal _handle of the database connection.
    +/
    @property sqlite3* handle() @safe pure nothrow
    {
        return core.handle;
    }

    /++
    Explicitly closes the database.

    After this function has been called successfully, using the database or one of its
    prepared statement is an error.
    +/
    void close()
    {
        auto result = sqlite3_close(handle);
        enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
        core.handle = null;
    }

    /++
    Executes a single SQL statement and returns the results directly. It's the equivalent
    of $(D prepare(sql).execute()).

    The results become undefined when the Database goes out of scope and is destroyed.
    +/
    ResultRange execute(string sql)
    {
        return prepare(sql).execute();
    }
    ///
    unittest
    {
        auto db = Database(":memory:");
        db.execute("VACUUM");
    }

    /++
    Runs an SQL script that can contain multiple statements.

    Params:
        sql = The code of the script.

        dg = A delegate to call for each statement to handle the results. The passed
        ResultRange will be empty if a statement doesn't return rows. If the delegate
        return false, the execution is aborted.
    +/
    void run(string sql, scope bool delegate(ResultRange) dg = null)
    {
        do
        {
            auto stmt = prepare(sql);
            auto results = stmt.execute();
            if (dg && !dg(results))
                return;
            sql = stmt.core.next;
        }
        while (sql.length);
    }
    ///
    unittest
    {
        auto db = Database(":memory:");
        db.run(`CREATE TABLE test1 (val INTEGER);
                CREATE TABLE test2 (val FLOAT);`);
    }

    /++
    Prepares (compiles) a single SQL statement and returngs it, so that it can be bound to
    values before execution.

    The statement becomes invalid if the Database goes out of scope and is destroyed.
    +/
    Statement prepare(string sql)
    {
        return Statement(core.handle, sql);
    }

    /// Convenience functions equivalent to an SQL statement.
    void begin() { execute("BEGIN"); }
    /// Ditto
    void commit() { execute("COMMIT"); }
    /// Ditto
    void rollback() { execute("ROLLBACK"); }

    /++
    Returns the rowid of the last INSERT statement.
    +/
    long lastInsertRowid()
    {
        return sqlite3_last_insert_rowid(core.handle);
    }

    /++
    Gets the number of database rows that were changed, inserted or deleted by the most
    recently executed SQL statement.
    +/
    @property int changes() nothrow
    {
        assert(core.handle);
        return sqlite3_changes(core.handle);
    }

    /++
    Gets the number of database rows that were changed, inserted or deleted since the
    database was opened.
    +/
    @property int totalChanges() nothrow
    {
        assert(core.handle);
        return sqlite3_total_changes(core.handle);
    }

    /++
    Gets the SQLite error code of the last operation.
    +/
    @property int errorCode() nothrow
    {
        return core.handle ? sqlite3_errcode(core.handle) : 0;
    }

    /+
    Helper function to translate the arguments values of a D function into Sqlite values.
    +/
    private static @property string block_read_values(size_t n, string name, PT...)()
    {
        static if (n == 0)
            return null;
        else
        {
            enum index = n - 1;
            alias Unqual!(PT[index]) UT;
            static if (isBoolean!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_INTEGER, new SqliteException(
                        "argument @{n} of function @{name}() should be a boolean"));
                    args[@{index}] = sqlite3_value_int64(argv[@{index}]) != 0;
                };
            else static if (isIntegral!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_INTEGER, new SqliteException(
                        "argument @{n} of function @{name}() should be of an integral type"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_int64(argv[@{index}]));
                };
            else static if (isFloatingPoint!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_FLOAT, new SqliteException(
                        "argument @{n} of function @{name}() should be a floating point"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_double(argv[@{index}]));
                };
            else static if (isSomeString!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_type(argv[@{index}]);
                    enforce(type == SQLITE3_TEXT, new SqliteException(
                        "argument @{n} of function @{name}() should be a string"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_text(argv[@{index}]));
                };
            else static if (isArray!UT && is(Unqual!(ElementType!UT) : ubyte))
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_type(argv[@{index}]);
                    enforce(type == SQLITE_BLOB, new SqliteException(
                        "argument @{n} of function @{name}() should be of an array of bytes (BLOB)"));
                    n = sqlite3_value_bytes(argv[@{index}]);
                    blob.length = n;
                    memcpy(blob.ptr, sqlite3_value_blob(argv[@{index}]), n);
                    args[@{index}] = to!(PT[@{index}])(blob.dup);
                };
            else static if (is(UT == void*))
                enum templ = q{
                    @{previous_block}
                };
            else
                static assert(false, PT[index].stringof ~ " is not a compatible argument type");

            return render(templ, [
                "previous_block": block_read_values!(n - 1, name, PT),
                "index":  to!string(index),
                "n": to!string(n),
                "name": name
            ]);
        }
    }

    /+
    Helper function to translate the return of a function into a Sqlite value.
    +/
    private static @property string block_return_result(RT...)()
    {
        static if (isIntegral!RT || isBoolean!RT)
            return q{
                auto result = to!long(tmp);
                sqlite3_result_int64(context, result);
            };
        else static if (isFloatingPoint!RT)
            return q{
                auto result = to!double(tmp);
                sqlite3_result_double(context, result);
            };
        else static if (isSomeString!RT)
            return q{
                auto result = to!string(tmp);
                if (result)
                    sqlite3_result_text(context, cast(char*) result.toStringz(), -1, null);
                else
                    sqlite3_result_null(context);
            };
        else static if (isArray!RT && is(Unqual!(ElementType!RT) == ubyte))
            return q{
                auto result = to!(ubyte[])(tmp);
                if (result)
                    sqlite3_result_blob(context, cast(void*) result.ptr, cast(int) result.length, null);
                else
                    sqlite3_result_null(context);
            };
        else
            static assert(false, RT.stringof ~ " is not a compatible return type");
    }

    /++
    Creates and registers a simple function in the database.

    Params:
        fun = An alias to the D implementation of the function. The function $(D_PARAM fun)
        must satisfy these criteria:
            $(UL
                $(LI It must not be a variadic.)
                $(LI Its arguments must all have a type that is compatible with SQLite types:
                boolean, integral, floating point, string, or array of bytes (BLOB types).)
                $(LI It can have only one parameter of type $(D void*) and it must be the
                last one.)
                $(LI Its return value must also be of a compatible type.)
            )

        name = The name that the function will have in the database; this name defaults to
        the identifier of $(D_PARAM fun).

        det = Tells SQLite whether the result of the function is deterministic, i.e. if the
        result is the same when called with the same parameters. Recent versions of SQLite
        perform optimizations based on this. Set to $(D Deterministic.no) otherwise.

        userData = A pointer to some user data, that will be passed to $(D_PARAM fun) as
        its last argument if its type is $(D void*).

    See_Also: $(LINK http://www.sqlite.org/c3ref/create_function.html).
    +/
    void createFunction(alias fun,
                        string name = __traits(identifier, fun),
                        Deterministic det = Deterministic.yes)
        (void* userData = null)
    {
        static assert(isCallable!fun, "expecting a callable");
        static assert(__traits(isStaticFunction, fun),
            "function with context pointers are not supported");
        static assert(variadicFunctionStyle!(fun) == Variadic.no,
            "variadic functions are not supported");

        enum funpointer = &fun;

        alias PTorig = staticMap!(Unqual, ParameterTypeTuple!fun);
        static assert(staticIndexOf!(void*, PTorig).among(-1, PTorig.length - 1),
                      "The paramater of type void* must be the last one");
        enum hasVoid = staticIndexOf!(void*, PTorig) >= 0;
        alias PT = Erase!(void*, PTorig);
        alias ReturnType!fun RT;

        enum x_func = q{
            extern(C) static void @{name}(sqlite3_context* context, int argc, sqlite3_value** argv)
            {
                PT args;
                int type, n;
                @{blob}

                @{block_read_values}

                static if (hasVoid)
                    auto userData = sqlite3_user_data(context);

                try
                {
                    static if (hasVoid)
                        auto tmp = funpointer(args, userData);
                    else
                        auto tmp = funpointer(args);
                    mixin(block_return_result!RT);
                }
                catch (Exception e)
                {
                    auto txt = "error in function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_func_mix = render(x_func, [
            "name": name,
            "blob": staticIndexOf!(ubyte[], PT) >= 0 ? q{ubyte[] blob;} : "",
            "block_read_values": block_read_values!(PT.length, name, PT)
        ]);

        mixin(x_func_mix);

        assert(core.handle);
        auto result = sqlite3_create_function(
            core.handle,
            name.toStringz(),
            PT.length,
            SQLITE_UTF8 | det,
            userData,
            mixin(format("&%s", name)),
            null,
            null
        );
        enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
    }
    ///
    unittest // Function creation
    {
        static string my_msg(string name)
        {
            return "Hello, %s!".format(name);
        }

        auto db = Database(":memory:");
        db.createFunction!my_msg();

        auto msg = db.execute("SELECT my_msg('John')")
                     .oneValue!string;
        assert(msg == "Hello, John!");
    }
    ///
    unittest // Function creation with user data
    {
        static string fun(string msg, void* data)
        {
            auto ptr = cast(int*) data;
            return "%s %d".format(msg, *ptr);
        }

        int value = 42;
        auto db = Database(":memory:");
        db.createFunction!fun(&value);
        auto msg = db.execute("SELECT fun('The number is')")
                     .oneValue!string;
        assert(msg == "The number is 42");
    }

    /++
    Creates and registers a new aggregate function in the database.

    Params:
        Aggregate = The $(D struct) implementing the aggregate. Aggregate must be a
        default-constructible $(DK struct) that implements at least these two methods: $(D
        accumulate) and $(D result).

        name = The name that the function will have in the database; this name defaults to
        the identifier of $(D_PARAM Aggregate).

        det = Tells SQLite whether the result of the function is deterministic, i.e. if the
        result is the same when called with the same parameters. Recent versions of SQLite
        perform optimizations based on this. Set to $(D Deterministic.no) otherwise.

    See_Also: $(LINK http://www.sqlite.org/c3ref/create_function.html).
    +/
    void createAggregate(Aggregate,
                         string name = __traits(identifier, Aggregate),
                         Deterministic det = Deterministic.yes)()
    {
        static assert(is(Aggregate == struct),
            name ~ " shoud be a struct");
        static assert(is(typeof(Aggregate.accumulate) == function),
            name ~ " shoud define accumulate()");
        static assert(is(typeof(Aggregate.result) == function),
            name ~ " shoud define result()");
        static assert(variadicFunctionStyle!(Aggregate.accumulate) == Variadic.no,
            "variadic functions are not supported");
        static assert(variadicFunctionStyle!(Aggregate.result) == Variadic.no,
            "variadic functions are not supported");

        alias staticMap!(Unqual, ParameterTypeTuple!(Aggregate.accumulate)) PT;
        alias ReturnType!(Aggregate.result) RT;

        enum x_step = q{
            extern(C) static
            void @{name}_step(sqlite3_context* context, int argc, sqlite3_value** argv)
            {
                auto agg = cast(Aggregate*) sqlite3_aggregate_context(context, Aggregate.sizeof);
                if (!agg)
                {
                    sqlite3_result_error_nomem(context);
                    return;
                }

                PT args;
                int type;
                @{blob}

                @{block_read_values}

                try
                {
                    agg.accumulate(args);
                }
                catch (Exception e)
                {
                    auto txt = "error in aggregate function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_step_mix = render(x_step, [
            "name": name,
            "blob": staticIndexOf!(ubyte[], PT) >= 0 ? q{ubyte[] blob;} : "",
            "block_read_values": block_read_values!(PT.length, name, PT)
        ]);

        mixin(x_step_mix);

        enum x_final = q{
            extern(C) static void @{name}_final(sqlite3_context* context)
            {
                Aggregate* agg = cast(Aggregate*) sqlite3_aggregate_context(context, Aggregate.sizeof);
                if (!agg)
                {
                    sqlite3_result_error_nomem(context);
                    return;
                }

                try
                {
                    auto tmp = agg.result();
                    mixin(block_return_result!RT);
                }
                catch (Exception e)
                {
                    auto txt = "error in aggregate function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_final_mix = render(x_final, [
            "name": name
        ]);

        mixin(x_final_mix);

        assert(core.handle);
        auto result = sqlite3_create_function(
            core.handle,
            name.toStringz(),
            PT.length,
            SQLITE_UTF8 | det,
            null,
            null,
            mixin(format("&%s_step", name)),
            mixin(format("&%s_final", name))
            );
        enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
    }
    ///
    unittest // Aggregate creation
    {
        struct weighted_average
        {
            double total_value = 0.0;
            double total_weight = 0.0;

            void accumulate(double value, double weight)
            {
                total_value += value * weight;
                total_weight += weight;
            }

            double result()
            {
                return total_value / total_weight;
            }
        }

        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (value FLOAT, weight FLOAT)");
        db.createAggregate!(weighted_average, "w_avg")();

        auto statement = db.prepare("INSERT INTO test (value, weight) VALUES (?1, ?2)");
        double[double] list = [11.5: 3, 14.8: 1.6, 19: 2.4];
        foreach (value, weight; list)
        {
            statement.bind(1, value);
            statement.bind(2, weight);
            statement.execute();
            statement.reset();
        }

        auto w_avg = db.execute("SELECT w_avg(value, weight) FROM test")
                       .oneValue!double;
        import std.math: approxEqual;
        assert(approxEqual(w_avg, (11.5*3 + 14.8*1.6 + 19*2.4)/(3 + 1.6 + 2.4)));
    }

    /++
    Creates and registers a collation function in the database.

    Params:
        fun = An alias to the D implementation of the function. The function $(D_PARAM fun)
        must satisfy these criteria:
            $(UL
                $(LI If s1 is less than s2, $(D ret < 0).)
                $(LI If s1 is equal to s2, $(D ret == 0).)
                $(LI If s1 is greater than s2, $(D ret > 0).)
                $(LI If s1 is equal to s2, then s2 is equal to s1.)
                $(LI If s1 is equal to s2 and s2 is equal to s3, then s1 is equal to s3.)
                $(LI If s1 is less than s2, then s2 is greater than s1.)
                $(LI If s1 is less than s2 and s2 is less than s3, then s1 is less than s3.)
            )

        name = The name that the function will have in the database; this name defaults to
        the identifier of $(D_PARAM fun).

    See_Also: $(LINK http://www.sqlite.org/lang_aggfunc.html)
    +/
    void createCollation(alias fun, string name = __traits(identifier, fun))()
    {
        static assert(isCallable!fun, "expecting a callable");
        static assert(__traits(isStaticFunction, fun),
            "function with context pointers are not supported");
        static assert(variadicFunctionStyle!(fun) == Variadic.no,
            "variadic functions are not supported");

        alias ParameterTypeTuple!fun PT;
        static assert(isSomeString!(PT[0]),
            "the first argument of function " ~ name ~ " should be a string");
        static assert(isSomeString!(PT[1]),
            "the second argument of function " ~ name ~ " should be a string");
        static assert(isImplicitlyConvertible!(ReturnType!fun, int),
            "function " ~ name ~ " should return a value convertible to an int");

        enum x_compare = q{
            extern (C) static int @{name}(void*, int n1, const(void*) str1, int n2, const(void* )str2)
            {
                char[] s1, s2;
                s1.length = n1;
                s2.length = n2;
                memcpy(s1.ptr, str1, n1);
                memcpy(s2.ptr, str2, n2);
                return fun(cast(immutable) s1, cast(immutable) s2);
            }
        };
        mixin(render(x_compare, ["name": name]));

        assert(core.handle);
        auto result = sqlite3_create_collation(
            core.handle,
            name.toStringz(),
            SQLITE_UTF8,
            null,
            mixin("&" ~ name)
            );
        enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
    }
    ///
    unittest // Collation creation
    {
        static int my_collation(string s1, string s2)
        {
            import std.uni;
            return icmp(s1, s2);
        }

        auto db = Database(":memory:");
        db.createCollation!my_collation();
        db.execute("CREATE TABLE test (word TEXT)");

        auto statement = db.prepare("INSERT INTO test (word) VALUES (?)");
        foreach (word; ["straße", "strasses"])
        {
            statement.bind(1, word);
            statement.execute();
            statement.reset();
        }

        auto word = db.execute("SELECT word FROM test ORDER BY word COLLATE my_collation")
                      .oneValue!string;
        assert(word == "straße");
    }

    /++
    Registers an update _hook.

    See_Also: $(LINK http://www.sqlite.org/c3ref/commit_hook.html).
    +/
    void setUpdateHook(scope void delegate(int type, string dbName, string tableName, long rowid) hook)
    {
        alias HookFun = void function(int type, string dbName, string tableName, long rowid);

        struct del
        {
            HookFun funcptr;
            void* ptr;
        }
        
        extern(C) static void callback(void* ptr, int type,
                                       char* dbName, char* tableName,
                                       sqlite3_int64 rowid)
        {
            auto d = *(cast(del*) ptr);
            void delegate(int type, string dbName, string tableName, long rowid) dg;
            dg.ptr = d.ptr;
            dg.funcptr = d.funcptr;
            return dg(type, dbName.to!string, tableName.to!string, rowid);
        }
        
        sqlite3_update_hook(core.handle, &callback,
                            cast(void*) new del(hook.funcptr, hook.ptr));
    }
    ///
    unittest
    {
        int i;
        auto db = Database(":memory:");
        db.setUpdateHook((int type, string dbName, string tableName, long rowid) {
            assert(type == SQLITE_INSERT);
            assert(dbName == "main");
            assert(tableName == "test");
            assert(rowid == 1);
            i = 42;
        });
        db.execute("CREATE TABLE test (val INTEGER)");
        db.execute("INSERT INTO test VALUES (100)");
        assert(i == 42);
    }

    /++
    Registers a commit _hook or a rollback _hook.
    
    Params:        
        hook = For the commit hook, a delegate that should return 0 if the operation must be
        aborted or another value if it can continue.

    See_Also: $(LINK http://www.sqlite.org/c3ref/commit_hook.html).
    +/
    void setCommitHook(int delegate() hook)
    {
        struct del
        {
            int function() funcptr;
            void* ptr;
        }

        extern(C) static int callback(void* ptr)
        {
            auto d = *(cast(del*) ptr);
            int delegate() dg;
            dg.ptr = d.ptr;
            dg.funcptr = d.funcptr;
            return dg();
        }

        sqlite3_commit_hook(core.handle, &callback,
                            cast(void*) new del(hook.funcptr, hook.ptr));
    }
    /// Ditto
    void setRollbackHook(void delegate() hook)
    {
        struct del
        {
            void function() funcptr;
            void* ptr;
        }
        
        extern(C) static void callback(void* ptr)
        {
            auto d = *(cast(del*) ptr);
            void delegate() dg;
            dg.ptr = d.ptr;
            dg.funcptr = d.funcptr;
            dg();
        }
        
        sqlite3_rollback_hook(core.handle, &callback,
                              cast(void*) new del(hook.funcptr, hook.ptr));
    }
    ///
    unittest
    {
        int i;
        auto db = Database(":memory:");
        db.setCommitHook({ i = 42; return SQLITE_OK; });
        db.setRollbackHook({ i = 666; });
        db.begin();
        db.execute("CREATE TABLE test (val INTEGER)");
        db.rollback();
        assert(i == 666);
        db.begin();
        db.execute("CREATE TABLE test (val INTEGER)");
        db.commit();
        assert(i == 42);
    }
    
    /++
    Registers a progress handler _hook.
        
    Params:
        pace = The approximate number of virtual machine instructions that are evaluated
        between successive invocations of the hook.
        
        hook = A delegate that should return 0 if the operation must be aborted or another
        value if it can continue.
        
    See_Also: $(LINK http://www.sqlite.org/c3ref/progress_handler.html)
    +/
    void setProgressHandler(int pace, int delegate() hook)
    {
        struct del
        {
            int function() funcptr;
            void* ptr;
        }

        extern(C) static int callback(void* ptr)
        {
            auto d = *(cast(del*) ptr);
            int delegate() dg;
            dg.ptr = d.ptr;
            dg.funcptr = d.funcptr;
            return dg();
        }

        sqlite3_progress_handler(core.handle, pace, &callback,
                                 cast(void*) new del(hook.funcptr, hook.ptr));
    }
}
///
unittest // Documentation example
{
    // Note: exception handling is left aside for clarity.

    // Open a database in memory.
    auto db = Database(":memory:");

    // Create a table
    db.execute(
        "CREATE TABLE person (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            score FLOAT,
            photo BLOB
         )"
    );

    // Populate the table

    // Prepare an INSERT statement
    auto statement = db.prepare(
        "INSERT INTO person (name, score, photo)
         VALUES (:name, :score, :photo)"
    );

    // Bind values one by one (by parameter name or index)
    statement.bind(":name", "John");
    statement.bind(":score", 77.5);
    statement.bind(3, [0xDE, 0xEA, 0xBE, 0xEF]);
    statement.execute();

    statement.reset(); // Need to reset the statement after execution.

    // Bind muliple values at once
    statement.bindAll("John", 46.8, null);
    statement.execute();

    // Count the changes
    assert(db.totalChanges == 2);

    // Count the Johns in the table.
    auto count = db.execute("SELECT count(*) FROM person WHERE name == 'John'")
                   .oneValue!long;
    assert(count == 2);

    // Read the data from the table lazily
    auto results = db.execute("SELECT * FROM person");
    foreach (row; results)
    {
        // Retrieve "id", which is the column at index 0, and contains an int,
        // e.g. using the peek function (best performance).
        auto id = row.peek!long(0);

        // Retrieve "name", e.g. using opIndex(string), which returns a ColumnData.
        auto name = row["name"].as!string;

        // Retrieve "score", which is at index 3, e.g. using the peek function.
        auto score = row.peek!double("score");

        // Retrieve "photo", e.g. using opIndex(index),
        // which returns a ColumnData.
        auto photo = row[3].as!(ubyte[]);

        // ... and use all these data!
    }

    // Read all the table in memory at once
    auto data = RowCache(db.execute("SELECT * FROM person"));
    foreach (row; data)
    {
        auto id = row[0].as!long;
        auto last = row["name"];
        auto score = row["score"].as!double;
        auto photo = row[3].as!(ubyte[]);
        // etc.
    }
}

unittest // Database construction
{
    Database db1;
    auto db2 = db1;
    db1 = Database(":memory:");
    db2 = Database("");
    auto db3 = Database(null);
    db1 = db2;
    assert(db2.core.refCountedStore.refCount == 2);
    assert(db1.core.refCountedStore.refCount == 2);
}

unittest // Execute an SQL statement
{
    auto db = Database(":memory:");
    db.run("");
    db.run("-- This is a comment!");
    db.run(";");
    db.run("ANALYZE; VACUUM;");
}

unittest // Unexpected multiple statements
{
    auto db = Database(":memory:");
    db.execute("BEGIN; CREATE TABLE test (val INTEGER); ROLLBACK;");
    assertThrown(db.execute("DROP TABLE test"));

    db.execute("CREATE TABLE test (val INTEGER); DROP TABLE test;");
    assertNotThrown(db.execute("DROP TABLE test"));

    db.execute("SELECT 1; CREATE TABLE test (val INTEGER); DROP TABLE test;");
    assertThrown(db.execute("DROP TABLE test"));
}

unittest // Multiple statements with callback
{
    auto db = Database(":memory:");
    RowCache[] rows;
    db.run("SELECT 1, 2, 3; SELECT 'A', 'B', 'C';", (ResultRange r) {
        rows ~= RowCache(r);
        return true;
    });
    assert(equal(rows[0][0], [1, 2, 3]));
    assert(equal(rows[1][0], ["A", "B", "C"]));
}


private string errmsg(sqlite3* db)
{
    return sqlite3_errmsg(db).to!string;
}

private string errmsg(sqlite3_stmt* stmt)
{
    return errmsg(sqlite3_db_handle(stmt));
}


/++
An SQLite statement execution.

This struct is a reference-counted wrapper around a $(D sqlite3_stmt*) pointer. Instances
of this struct are typically returned by $(D Database.prepare()).
+/
struct Statement
{
private:
    struct _Core
    {
        sqlite3_stmt* handle; // null if error or empty statement
        string next;

        ~this()
        {
            auto result = sqlite3_finalize(handle);
            enforce(result == SQLITE_OK, new SqliteException(errmsg(handle), result));
            handle = null;
        }

        @disable this(this);
        void opAssign(_Core) { assert(false); }
    }
    alias RefCounted!(_Core, RefCountedAutoInitialize.no) Core;
    Core core;

    this(sqlite3* dbHandle, string sql)
    {
        sqlite3_stmt* handle;
        const(char*) ptail;
        auto result = sqlite3_prepare_v2(
            dbHandle,
            cast(char*) sql.toStringz(),
            cast(int) sql.length,
            &handle,
            &ptail
        );
        enforce(result == SQLITE_OK, new SqliteException(errmsg(dbHandle), result, sql));
        core = Core(handle);
        if (ptail)
        {
            // Offset sometimes seems to be undefined if statement doesn't end with ";"
            auto offset = min(ptail - sql.ptr, sql.length);
            core.next = sql[offset .. $];
        }
    }

    int parameterCount() nothrow
    {
        if (core.handle)
            return sqlite3_bind_parameter_count(core.handle);
        else
            return 0;
    }

public:
    /++
    Gets the SQLite internal _handle of the statement.
    +/
    @property sqlite3_stmt* handle()
    {
        return core.handle;
    }

    /++
    Binds values to parameters of this statement.

    Params:
        index = The index of the parameter (starting from 1).

        value = The bound _value. The type of value must be compatible with the SQLite
        types: it must be a boolean or numeric type, a string or an array.
    +/
    void bind(T)(int index, T value)
    {
        alias Unqual!T U;
        int result;

        static if (is(U == typeof(null)) || is(U == void*))
        {
            result = sqlite3_bind_null(core.handle, index);
        }
        else static if (isIntegral!U || isSomeChar!U)
        {
            result = sqlite3_bind_int64(core.handle, index, cast(long) value);
        }
        else static if (isFloatingPoint!U)
        {
            result = sqlite3_bind_double(core.handle, index, value);
        }
        else static if (isSomeString!U)
        {
            string utf8 = value.to!string;
            result = sqlite3_bind_text(core.handle,
                                       index,
                                       cast(char*) utf8.toStringz(),
                                       cast(int) utf8.length,
                                       null);
        }
        else static if (isArray!U)
        {
            if (!value.length)
                result = sqlite3_bind_null(core.handle, index);
            else
            {
                auto bytes = cast(ubyte[]) value;
                result = sqlite3_bind_blob(core.handle,
                                           index,
                                           cast(void*) bytes.ptr,
                                           cast(int) bytes.length,
                                           null);
            }
        }
        else
            static assert(false, "cannot bind a value of type " ~ U.stringof);

        enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
    }

    /++
    Binds values to parameters of this statement.

    Params:
        name = The name of the parameter, including the ':', '@' or '$' that introduced it.

        value = The bound _value. The type of value must be compatible with the SQLite
        types: it must be a boolean or numeric type, a string or an array.

    Warning:
        While convenient, this overload of $(D bind) is less performant, because it has to
        retrieve the column index with a call to the SQLite function $(D
        sqlite3_bind_parameter_index).
    +/
    void bind(T)(string name, T value)
    {
        auto index = sqlite3_bind_parameter_index(core.handle, cast(char*) name.toStringz());
        enforce(index > 0, new SqliteException(format("no parameter named '%s'", name)));
        bind(index, value);
    }

    /++
    Binds all the arguments at once in order.
    +/
    void bindAll(Args...)(Args args)
    {
        foreach (index, _; Args)
            bind(index + 1, args[index]);
    }

    /++
    Clears the bindings.

    This does not reset the statement. Use $(D Statement.reset()) for this.
    +/
    void clearBindings()
    {
        if (core.handle)
        {
            auto result = sqlite3_clear_bindings(core.handle);
            enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
        }
    }

    /++
    Executes the statement and return a (possibly empty) range of results.
    +/
    ResultRange execute()
    {
        return ResultRange(this);
    }

    /++
    Resets a this statement before a new execution.

    Calling this method invalidates any $(D ResultRange) struct returned by a previous call
    to $(D Database.execute()) or $(D Statement.execute()).

    This does not clear the bindings. Use $(D Statement.clear()) for this.
    +/
    void reset()
    {
        if (core.handle)
        {
            auto result = sqlite3_reset(core.handle);
            enforce(result == SQLITE_OK, new SqliteException(errmsg(core.handle), result));
        }
    }
}

unittest // Simple parameters binding
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto statement = db.prepare("INSERT INTO test (val) VALUES (?)");
    statement.bind(1, 42);
    statement.execute();
    statement.reset();
    statement.bind(1, 42);
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    foreach (row; results)
        assert(row.peek!int(0) == 42);
}

unittest // Multiple parameters binding
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (i INTEGER, f FLOAT, t TEXT)");
    auto statement = db.prepare("INSERT INTO test (i, f, t) VALUES (:i, @f, $t)");
    assert(statement.parameterCount == 3);
    statement.bind("$t", "TEXT");
    statement.bind(":i", 42);
    statement.bind("@f", 3.14);
    statement.execute();
    statement.reset();
    statement.bind(1, 42);
    statement.bind(2, 3.14);
    statement.bind(3, "TEXT");
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    foreach (row; results)
    {
        assert(row.length == 3);
        assert(row.peek!int("i") == 42);
        assert(row.peek!double("f") == 3.14);
        assert(row.peek!string("t") == "TEXT");
    }
}

unittest // Multiple parameters binding: tuples
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (i INTEGER, f FLOAT, t TEXT)");
    auto statement = db.prepare("INSERT INTO test (i, f, t) VALUES (?, ?, ?)");
    statement.bindAll(42, 3.14, "TEXT");
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    foreach (row; results)
    {
        assert(row.length == 3);
        assert(row.peek!int(0) == 42);
        assert(row.peek!double(1) == 3.14);
        assert(row.peek!string(2) == "TEXT");
    }
}


/++
An input range interface to access the results of the execution of a statement.

The elements of the range are $(D Row) structs. A $(D Row) is just a view of the current
row when iterating the results of a $(D ResultRange). It becomes invalid as soon as $(D
ResultRange.popFront()) is called (it contains undefined data afterwards). Use $(D
RowCache) to store the content of rows past the execution of the statement.

Instances of this struct are typically returned by $(D Database.execute()) or $(D
Statement.execute()).
+/
struct ResultRange
{
private:
    struct _Core
    {
        Statement statement;
        int state;

        @disable this(this);
        void opAssign(_Core) { assert(false); }
    }
    alias RefCounted!(_Core, RefCountedAutoInitialize.no) Core;
    Core core;

    this(Statement statement)
    {
        core = Core(statement);
        if (core.statement.handle !is null)
            core.state = sqlite3_step(core.statement.handle);
        else
            core.state = SQLITE_DONE;
        enforce(core.state == SQLITE_ROW || core.state == SQLITE_DONE,
                new SqliteException(errmsg(core.statement.handle), core.state));
    }

public:
    /++
    Range primitives.
    +/
    @property bool empty()
    {
        assert(core.state);
        return core.state == SQLITE_DONE;
    }

    /// ditto
    @property Row front()
    {
        assert(core.state);
        enforce(!empty, new SqliteException("No rows available"));
        return Row(core.statement.handle);
    }

    /// ditto
    void popFront()
    {
        assert(core.state);
        enforce(!empty, new SqliteException("No rows available"));
        core.state = sqlite3_step(core.statement.handle);
        enforce(core.state == SQLITE_DONE || core.state == SQLITE_ROW,
                new SqliteException(errmsg(core.statement.handle), core.state));
    }

    /++
    Gets only the first value of the first row returned by the execution of the statement.
    +/
    auto oneValue(T)()
    {
        return front.peek!T(0);
    }
    ///
    unittest // One value
    {
        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (val INTEGER)");
        auto count = db.execute("SELECT count(*) FROM test").oneValue!long;
        assert(count == 0);
    }
}

unittest // Refcount tests
{
    auto db = Database(":memory:");
    {
        db.execute("CREATE TABLE test (val INTEGER)");
        auto tmp = db.prepare("INSERT INTO test (val) VALUES (?)");
        tmp.bind(1, 42);
        tmp.execute();
    }

    auto results = { return db.execute("SELECT * FROM test"); }();
    assert(!results.empty);
    assert(results.oneValue!int == 42);
    results.popFront();
    assert(results.empty);
}


/++
A SQLite row, implemented as a random-access range of ColumnData.
+/
struct Row
{
    private
    {
        sqlite3_stmt* statement;
        int frontIndex;
        int backIndex;
    }

    this(sqlite3_stmt* statement) nothrow
    {
        assert(statement);
        this.statement = statement;
        backIndex = sqlite3_column_count(statement) - 1;
    }

    /// Range interface.
    @property bool empty() @safe pure nothrow
    {
        return length == 0;
    }

    /// ditto
    @property ColumnData front() nothrow
    {
        return ColumnData(peek!Variant(0));
    }

    /// ditto
    void popFront() @safe pure nothrow
    {
        frontIndex++;
    }

    /// ditto
    @property Row save() @safe pure nothrow
    {
        Row ret;
        ret.statement = statement;
        ret.frontIndex = frontIndex;
        ret.backIndex = backIndex;
        return ret;
    }

    /// ditto
    @property ColumnData back() nothrow
    {
        return ColumnData(peek!Variant(backIndex - frontIndex));
    }

    /// ditto
    void popBack() @safe pure nothrow
    {
        backIndex--;
    }

    /// ditto
    @property int length() @safe pure nothrow
    {
        return backIndex - frontIndex + 1;
    }

    /// ditto
    ColumnData opIndex(int index)
    {
        int i =  cast(int) index + frontIndex;
        enforce(i >= 0 && i <= backIndex, new SqliteException(format("invalid column index: %d", i)));
        return ColumnData(peek!Variant(index));
    }

    /++
    Returns the data of a column as a $(D ColumnData).

    Params:
        name = The name of the column, as specified in the prepared statement with an AS
        clause.
    +/
    ColumnData opIndex(string name)
    {
        return ColumnData(peek!Variant(name));
    }

    /++
    Returns the data of a column.

    Contraty to $(D opIndex), the $(D peek) functions return the data directly,
    automatically cast to T, without the overhead of using a wrapped $(D Variant) ($(D
    ColumnData)).

    Params:
        T = The type of the returned data. T must be a boolean, a built-in numeric type, a
        string, an array or a Variant.

        index = The index of the column in the prepared statement.

    Returns: A value of type T, or T.init if the data is NULL.

    Warning:
        The result is undefined if then index is out of range.
    +/
    auto peek(T)(int index)
    {
        int i =  cast(int) index + frontIndex;

        static if (isBoolean!T || isIntegral!T)
        {
            return cast(T) sqlite3_column_int64(statement, i);
        }
        else static if (isFloatingPoint!T)
        {
            if (sqlite3_column_type(statement, i) == SQLITE_NULL)
                return double.nan;
            return cast(T) sqlite3_column_double(statement, i);
        }
        else static if (isSomeString!T)
        {
            return sqlite3_column_text(statement, i).to!T;
        }
        else static if (isArray!T)
        {
            auto ptr = sqlite3_column_blob(statement, i);
            auto length = sqlite3_column_bytes(statement, i);
            ubyte[] blob;
            blob.length = length;
            memcpy(blob.ptr, ptr, length);
            return cast(T) blob;
        }
        else static if (is(T == Variant))
        {
            auto type = sqlite3_column_type(statement, i);
            final switch (type)
            {
                case SQLITE_INTEGER:
                    return Variant(peek!long(index));

                case SQLITE_FLOAT:
                    return Variant(peek!double(index));

                case SQLITE3_TEXT:
                    return Variant(peek!string(index));

                case SQLITE_BLOB:
                    return Variant(peek!(ubyte[])(index));

                case SQLITE_NULL:
                    return Variant();
            }
        }
        else
            static assert(false, "value cannot be converted to type " ~ T.stringof);
    }

    /++
    Returns the data of a column.

    Contraty to $(D opIndex), the $(D peek) functions return the data directly,
    automatically cast to T, without the overhead of using a wrapped $(D Variant) ($(D
    ColumnData)).

    Params:
        T = The type of the returned data. T must be a boolean, a built-in numeric type, a
        string, an array or a Variant.

        name = The name of the column, as specified in the prepared statement with an AS
        clause.

    Returns: A value of type T, or T.init if the data is NULL.

    Warning:
        The names of all the columns are tested each time this function is called: use
        numeric indexing for better performance.
    +/
    auto peek(T)(string name)
    {
        foreach (i; frontIndex .. backIndex + 1)
            if (sqlite3_column_name(statement, i).to!string == name)
                return peek!T(i);

        throw new SqliteException("invalid column name: '%s'".format(name));
    }
}

version (unittest)
{
    static assert(isRandomAccessRange!Row);
    static assert(is(ElementType!Row == ColumnData));
}

unittest // Row random-access range interface
{
    auto db = Database(":memory:");

    {
        db.execute("CREATE TABLE test (a INTEGER, b INTEGER, c INTEGER, d INTEGER)");
        auto statement = db.prepare("INSERT INTO test (a, b, c, d) VALUES (?, ?, ?, ?)");
        statement.bind(1, 1);
        statement.bind(2, 2);
        statement.bind(3, 3);
        statement.bind(4, 4);
        statement.execute();
        statement.reset();
        statement.bind(1, 5);
        statement.bind(2, 6);
        statement.bind(3, 7);
        statement.bind(4, 8);
        statement.execute();
    }

    {
        auto results = db.execute("SELECT * FROM test");
        auto values = [1, 2, 3, 4, 5, 6, 7, 8];
        foreach (row; results)
        {
            while (!row.empty)
            {
                assert(row.front.as!int == values.front);
                row.popFront();
                values.popFront();
            }
        }
    }

    {
        auto results = db.execute("SELECT * FROM test");
        auto values = [4, 3, 2, 1, 8, 7, 6, 5];
        foreach (row; results)
        {
            while (!row.empty)
            {
                assert(row.back.as!int == values.front);
                row.popBack();
                values.popFront();
            }
        }
    }

    auto results = { return db.execute("SELECT * FROM test"); }();
    auto values = [1, 2, 3, 4, 5, 6, 7, 8];
    foreach (row; results)
    {
        while (!row.empty)
        {
            assert(row.front.as!int == values.front);
            row.popFront();
            values.popFront();
        }
    }
}


/++
The data retrived from a column, stored internally as a $(D Variant), which is accessible
through "$(D alias this)".
+/
struct ColumnData
{
    Variant variant;
    alias variant this;

    /++
    Returns the data converted to T. If the data is NULL, defaultValue is
    returned.
    +/
    auto as(T)(T defaultValue = T.init)
    {
        if (!variant.hasValue)
            return defaultValue;

        static if (isBoolean!T || isNumeric!T || isSomeChar!T || isSomeString!T)
        {
            return variant.coerce!T;
        }
        else static if (isArray!T)
        {
            auto a = variant.get!(ubyte[]);
            return cast(T) a;
        }
        else
            throw new SqliteException("Cannot convert value to type %s".format(T.stringof));
    }

    void toString(scope void delegate(const(char)[]) sink)
    {
        if (variant.hasValue)
            sink(variant.toString);
        else
            sink("NULL");
    }
}


unittest // Getting integral values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto statement = db.prepare("INSERT INTO test (val) VALUES (?)");
    statement.bind(1, cast(byte) 42);
    statement.execute();
    statement.reset();
    statement.bind(1, 42U);
    statement.execute();
    statement.reset();
    statement.bind(1, 42UL);
    statement.execute();
    statement.reset();
    statement.bind(1, '\x2A');
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    foreach (row; results)
        assert(row.peek!long(0) == 42);
}

unittest // Getting floating point values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val FLOAT)");

    auto statement = db.prepare("INSERT INTO test (val) VALUES (?)");
    statement.bind(1, 42.0F);
    statement.execute();
    statement.reset();
    statement.bind(1, 42.0);
    statement.execute();
    statement.reset();
    statement.bind(1, 42.0L);
    statement.execute();
    statement.reset();
    statement.bind(1, "42");
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    foreach (row; results)
        assert(row.peek!double(0) == 42.0);
}

unittest // Getting text values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val TEXT)");

    auto statement = db.prepare("INSERT INTO test (val) VALUES (?)");
    statement.bind(1, "I am a text.");
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    assert(results.front.peek!string(0) == "I am a text.");
}

unittest // Getting blob values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val BLOB)");

    auto statement = db.prepare("INSERT INTO test (val) VALUES (?)");
    ubyte[] array = [1, 2, 3];
    statement.bind(1, array);
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    foreach (row; results)
        assert(row.peek!(ubyte[])(0) ==  [1, 2, 3]);
}

unittest // Getting null values
{
    import std.math;

    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val TEXT)");

    auto statement = db.prepare("INSERT INTO test (val) VALUES (?)");
    statement.bind(1, null);
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    assert(results.front.peek!bool(0) == false);
    assert(results.front.peek!long(0) == 0);
    assert(results.front.peek!double(0).isnan);
    assert(results.front.peek!string(0) is null);
    assert(results.front.peek!(ubyte[])(0) is null);
    assert(results.front[0].as!bool == false);
    assert(results.front[0].as!long == 0);
    assert(results.front[0].as!double.isnan);
    assert(results.front[0].as!string is null);
    assert(results.front[0].as!(ubyte[]) is null);
}


/++
Caches all the results of a $(D Statement) in memory as $(D ColumnData).

Allows to iterate on the rows and their columns with an array-like interface. The rows can
be viewed as an array of $(D ColumnData) or as an associative array of $(D ColumnData)
indexed by the column names.
+/
struct RowCache
{
    struct CachedRow
    {
        ColumnData[] columns;
        alias columns this;

        int[string] columnIndexes;

        private this(Row row, int[string] columnIndexes) nothrow
        {
            this.columnIndexes = columnIndexes;

            auto colapp = appender!(ColumnData[]);
            foreach (i; 0 .. row.length)
                colapp.put(ColumnData(row.peek!Variant(i)));
            columns = colapp.data;
        }

        ColumnData opIndex(int index) nothrow
        {
            return columns[index];
        }

        ColumnData opIndex(string name)
        {
            auto index = name in columnIndexes;
            enforce(index, new SqliteException("Unknown column name: %s".format(name)));
            return columns[*index];
        }
    }

    CachedRow[] rows;
    alias rows this;

    private int[string] columnIndexes;

    /++
    Creates and populates the cache from the results of the statement.
    +/
    this(ResultRange results)
    {
        if (!results.empty)
        {
            auto first = results.front;
            foreach (i; 0 .. first.length)
            {
                auto name = sqlite3_column_name(first.statement, i).to!string;
                columnIndexes[name] = i;
            }
        }

        auto rowapp = appender!(CachedRow[]);
        while (!results.empty)
        {
            rowapp.put(CachedRow(results.front, columnIndexes));
            results.popFront();
        }
        rows = rowapp.data;
    }
}
///
unittest
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (msg TEXT, num FLOAT)");

    auto statement = db.prepare("INSERT INTO test (msg, num) VALUES (?1, ?2)");
    statement.bind(1, "ABC");
    statement.bind(2, 123);
    statement.execute();
    statement.reset();
    statement.bind(1, "DEF");
    statement.bind(2, 456);
    statement.execute();

    auto results = db.execute("SELECT * FROM test");
    auto data = RowCache(results);
    assert(data.length == 2);
    assert(data[0].front.as!string == "ABC");
    assert(data[0][1].as!int == 123);
    assert(data[1]["msg"].as!string == "DEF");
    assert(data[1]["num"].as!int == 456);
}

unittest // RowCache copies
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (msg TEXT)");
    auto statement = db.prepare("INSERT INTO test (msg) VALUES (?)");
    statement.bind(1, "ABC");
    statement.execute();

    static getdata(Database db)
    {
        return RowCache(db.execute("SELECT * FROM test"));
    }

    auto data = getdata(db);
    assert(data.length == 1);
    assert(data[0][0].as!string == "ABC");
}


/++
Turns $(D_PARAM value) into a _literal that can be used in an SQLite expression.
+/
string literal(T)(T value)
{
    static if (is(T == typeof(null)))
        return "NULL";
    else static if (isBoolean!T)
        return value ? "1" : "0";
    else static if (isNumeric!T)
        return value.to!string();
    else static if (isSomeString!T)
        return format("'%s'", value.replace("'", "''"));
    else static if (isArray!T)
        return "'X%(%X%)'".format(cast(ubyte[]) value);
    else
        static assert(false, "cannot make a literal of a value of type " ~ T.stringof);
}
///
unittest
{
    assert(null.literal == "NULL");
    assert(false.literal == "0");
    assert(true.literal == "1");
    assert(4.literal == "4");
    assert(4.1.literal == "4.1");
    assert("foo".literal == "'foo'");
    assert("a'b'".literal == "'a''b'''");
    auto a = cast(ubyte[]) x"DEADBEEF";
    assert(a.literal == "'XDEADBEEF'");
}

/++
Exception thrown when SQLite functions return an error.
+/
class SqliteException : Exception
{
    /++
    The _code of the error that raised the exception, or 0 if this _code is not known.
    +/
    int code;

    /++
    The SQL code that raised the exception, if applicable.
    +/
    string sql;

    private this(string msg, string sql, int code,
                 string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this.sql = sql;
        this.code = code;
        super(msg, file, line, next);
    }

    this(string msg, int code, string sql = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this("error %d: %s".format(code, msg), sql, code, file, line, next);
    }

    this(string msg, string sql = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this(msg, sql, 0, file, line, next);
    }
}

// Compile-time rendering of code templates.
private string render(string templ, string[string] args)
{
    string markupStart = "@{";
    string markupEnd = "}";

    string result;
    auto str = templ;
    while (true)
    {
        auto p_start = std.string.indexOf(str, markupStart);
        if (p_start < 0)
        {
            result ~= str;
            break;
        }
        else
        {
            result ~= str[0 .. p_start];
            str = str[p_start + markupStart.length .. $];

            auto p_end = std.string.indexOf(str, markupEnd);
            if (p_end < 0)
                assert(false, "Tag misses ending }");
            auto key = strip(str[0 .. p_end]);

            auto value = key in args;
            if (!value)
                assert(false, "Key '" ~ key ~ "' has no associated value");
            result ~= *value;

            str = str[p_end + markupEnd.length .. $];
        }
    }

    return result;
}

unittest // Code templates
{
    enum tpl = q{
        string @{function_name}() {
            return "Hello world!";
        }
    };
    mixin(render(tpl, ["function_name": "hello_world"]));
    static assert(hello_world() == "Hello world!");
}
