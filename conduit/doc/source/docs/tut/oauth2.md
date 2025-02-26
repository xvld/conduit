# Adding Authentication and Authorization with OAuth 2.0

Our `heroes` application lets anyone create or view the same set of heroes. We will continue to build on the last chapter's project, `heroes`, requiring a user to log in before viewing or creating heroes.

!!! note "We're Done With the Browser App" We're at the point now where using the browser application to test our Conduit app gets a bit cumbersome. From here on out, we'll use `curl`, `conduit document client` and tests.

## The Basics of OAuth 2.0

[OAuth 2.0](https://tools.ietf.org/html/rfc6749) is an authorization framework that also contains guidance on authentication. Authentication is the process of proving you are a particular user, typically through a username and password. Authorization is the process of ensuring that a user can access a particular resource or collection of resources. In our application, a user will have to be authenticated before being authorized to view or create heroes.

In a simple authentication and authorization scheme, each HTTP request contains the username and password \(credentials\) of the user in an `Authorization` header. There are a number of security risks involved in doing this, so OAuth 2.0 takes another approach: you send your credentials once, and get a 'access token' in return. You then send this access token in each request. Because the server grants the token, it knows that you've already entered your credentials \(you've _authenticated_\) and it remembers who the token belongs to. It's effectively the same thing as sending your credentials each time, except that the token has a time limit and can be revoked when things go wrong.

Conduit has a built-in OAuth 2.0 implementation that leverages the ORM. This implementation is part of the `conduit` package, but it is a separate library named `conduit/managed_auth`. It takes a few steps to set up that might be difficult to understand if you are not familiar with OAuth 2.0, but you'll get a well-tested, secure authorization implementation.

## Setting up OAuth 2.0: Creating a User Type

Our application needs some concept of a 'user' - a person who logs into the application to manage heroes. This user will have a username and password. In a later exercise, a user will also have a list of heroes that belong to them. Create a new file `model/user.dart` and enter the following code:

```dart
import 'package:conduit/managed_auth.dart';
import 'package:heroes/heroes.dart';
import 'package:heroes/model/hero.dart';

class User extends ManagedObject<_User> implements _User, ManagedAuthResourceOwner<_User> {}

class _User extends ResourceOwnerTableDefinition {}
```

The imported library `package:conduit/managed_auth.dart` contains types that use the ORM to store users, tokens and other OAuth 2.0 related data. One of those types is `ResourceOwnerTableDefinition`, the superclass of our user's table definition. This type contains all of the required fields that Conduit needs to implement authentication.

!!! tip "Resource Owners" A _resource owner_ is a more general term for a 'user' that comes from the OAuth 2.0 specification. In the framework, you'll see types and variables using some variant of _resource owner_, but for all intents and purposes, you can consider this a 'user'.

If you are curious, `ResourceOwnerTableDefinition` looks like this:

```dart
class ResourceOwnerTableDefinition {
  @primaryKey
  int id;

  @Column(unique: true, indexed: true)
  String username;

  @Column(omitByDefault: true)
  String hashedPassword;

  @Column(omitByDefault: true)
  String salt;

  ManagedSet<ManagedAuthToken> tokens;
}
```

Because these fields are in `User`'s table definition, our `User` table has all of these database columns.

!!! note "ManagedAuthResourceOwner" Note that `User` implements `ManagedAuthResourceOwner<_User>` - this is a requirement of any OAuth 2.0 resource owner type when using `package:conduit/managed_auth`.

## Setting up OAuth 2.0: AuthServer and its Delegate

Now that we have a user, we need some way to create new users and authenticate them. Authentication is fairly tricky, especially in OAuth 2.0, so there is a service object that does the hard part for us called an `AuthServer`. This type has all of the logic needed to authentication and authorize users. For example, an `AuthServer` can generate a new token if given valid user credentials.

In `channel.dart`, add the following imports to the top of your file:

```dart
import 'package:conduit/managed_auth.dart';
import 'package:heroes/model/user.dart';
```

Then, declare a new `authServer` property in your channel and initialize it in `prepare`:

```dart
class HeroesChannel extends ApplicationChannel {
  ManagedContext context;

  // Add this field
  AuthServer authServer;

  Future prepare() async {
    logger.onRecord.listen((rec) => print("$rec ${rec.error ?? ""} ${rec.stackTrace ?? ""}"));

    final config = HeroConfig(options.configurationFilePath);
    final dataModel = ManagedDataModel.fromCurrentMirrorSystem();
    final persistentStore = PostgreSQLPersistentStore.fromConnectionInfo(
      config.database.username,
      config.database.password,
      config.database.host,
      config.database.port,
      config.database.databaseName);

    context = ManagedContext(dataModel, persistentStore);

    // Add these two lines:
    final authStorage = ManagedAuthDelegate<User>(context);
    authServer = AuthServer(authStorage);
  }
  ...
```

While an `AuthServer` handles the logic of authentication and authorization, it doesn't know how to store or fetch the data it uses for those tasks. Instead, it relies on a _delegate_ object to handle storing and fetching data from a database. In our application, we use `ManagedAuthDelegate<T>` - from `package:conduit/managed_auth` - as the delegate. This type uses the ORM for these tasks; the type argument must be our application's user object.

!!! tip "Delegation" Delegation is a design pattern where an object has multiple callbacks that are grouped into an interface. Instead of defining a closure for each callback, a type implements methods that get called by the delegating object. It is a way of organizing large amounts of related callbacks into a tidy class.

By importing `conduit/managed_auth`, we've added a few more managed objects to our application \(to store tokens and other authentication data\) and we also have a new `User` managed object. It's a good time to run a database migration. From your project directory, run the following commands:

```text
conduit db generate
conduit db upgrade --connect postgres://heroes_user:password@localhost:5432/heroes
```

## Setting up OAuth 2.0: Registering Users

Now that we have the concept of a user, our database and application are set up to handle authentication, we can start creating new users. Let's create a new controller for registering users. This controller will accept `POST` requests that contain a username and password in the body. It will insert a new user into the database and securely hash the user's password.

Before we create this controller, there is something we need to consider: our registration endpoint will require the user's password, but we store the user's password as a cryptographic hash. This prevents someone with access to your database from knowing a user's password. In order to bind the body of a request to a `User` object, it needs a password field, but we don't want to store the password in the database without first hashing it.

We can accomplish this with _transient properties_. A transient property is a property of a managed object that isn't stored in the database. They are declared in the managed object subclass instead of the table definition. By default, a transient property is not read from a request body or encoded into a response body; unless we add the `Serialize` annotation to it. Add this property to your `User` type:

```dart
class User extends ManagedObject<_User> implements _User, ManagedAuthResourceOwner<_User> {
  @Serialize(input: true, output: false)
  String password;
}
```

This declares that a `User` has a transient property `password` that can be read on input \(from a request body\), but is not sent on output \(to a response body\). We don't have to run a database migration because transient properties are not stored in a database.

Now, create the file `controller/register_controller.dart` and enter the following code:

```dart
import 'dart:async';

import 'package:conduit/conduit.dart';
import 'package:heroes/model/user.dart';

class RegisterController extends ResourceController {
  RegisterController(this.context, this.authServer);

  final ManagedContext context;
  final AuthServer authServer;

  @Operation.post()
  Future<Response> createUser(@Bind.body() User user) async {
    // Check for required parameters before we spend time hashing
    if (user.username == null || user.password == null) {
      return Response.badRequest(
        body: {"error": "username and password required."});
    }

    user
      ..salt = AuthUtility.generateRandomSalt()
      ..hashedPassword = authServer.hashPassword(user.password, user.salt);

    return Response.ok(await Query(context, values: user).insert());
  }
}
```

This controller takes POST requests that contain a user. A user has many fields \(username, password, hashedPassword, salt\), but we will calculate the latter two and only require that the request contain the first two. The controller generates a salt and hash of the password before storing it in the database. In `channel.dart`, let's link this controller - don't forget to import it!

```dart
import 'package:heroes/controller/register_controller.dart';

...

  @override
  Controller get entryPoint {
    final router = Router();

    router
      .route('/heroes/[:id]')
      .link(() => HeroesController(context));

    router
      .route('/register')
      .link(() => RegisterController(context, authServer));

    return router;
  }
}
```

Let's run the application and create a new user using `curl` from the command-line. \(We'll specify `-n1` to designate using one isolate and speed up startup.\)

```text
conduit serve -n1
```

Then, issue a request to your server:

```dart
curl -X POST http://localhost:8888/register -H 'Content-Type: application/json' -d '{"username":"bob", "password":"password"}'
```

You'll get back the new user object and its username:

```text
{"id":1,"username":"bob"}
```

## Setting up OAuth 2.0: Authenticating Users

Now that we have a user with a password, we can create an endpoint that takes user credentials and returns an access token. The good news is that this controller already exists in Conduit, you just have to hook it up to a route. Update `entryPoint` in `channel.dart` to add an `AuthController` for the route `/auth/token`:

```dart
@override
Controller get entryPoint {
  final router = Router();

  // add this route
  router
    .route('/auth/token')
    .link(() => AuthController(authServer));

  router
    .route('/heroes/[:id]')
    .link(() => HeroesController(context));

  router
    .route('/register')
    .link(() => RegisterController(context, authServer));

  return router;
}
```

An `AuthController` follows the OAuth 2.0 specification for granting access tokens when given valid user credentials. To understand how a request to this endpoint must be structured, we need to discuss OAuth 2.0 _clients_. In OAuth 2.0, a client is an application that is allowed to access your server on behalf of a user. A client can be a browser application, a mobile application, another server, a voice assistant, etc. A client always has an identifier string, typically something like 'com.conduit.dart.account\_app.mobile'.

When authenticating, a user is always authenticated through a client. This client information must be attached to every authentication request, and the server must validate that the client had been previously registered. Therefore, we need to register a new client for our application. A client is stored in our application's database using the `conduit auth add-client` CLI. Run the following command from your project directory:

```text
conduit auth add-client --id com.heroes.tutorial --connect postgres://heroes_user:password@localhost:5432/heroes
```

!!! note "OAuth 2.0 Clients" A client must have an identifier, but it may also have a secret, redirect URI and list of allowed scopes. See the [guides on OAuth 2.0](oauth2.md) for how these options impacts authentication. Most notably, a client identifier must have a secret to issue a _refresh token_. Clients are stored in an application's database.

This will insert a new row into an OAuth 2.0 client table created by our last round of database migration and allow us to make authentication requests. An authentication request must meet all of the following criteria:

* the client identifier \(and secret, if it exists\) are included as a basic `Authorization` header.
* the username and password are included in the request body
* the key-value `grant_type=password` is included in the request body
* the request body content-type is `application/x-www-form-urlencoded`; this means the request body is effectively a query string \(e.g. `username=bob&password=pw&grant_type=password`\)

In Dart code, this would look like this:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart'
    as http; // Must include http: any package in your pubspec.yaml

Future<void> main() async {
  const clientID = "org.hasenbalg.zeiterfassung";
  const body = "username=bob&password=password&grant_type=password";

// Note the trailing colon (:) after the clientID.
// A client identifier secret would follow this, but there is no secret, so it is the empty string.
  final String clientCredentials =
      const Base64Encoder().convert("$clientID:".codeUnits);

  final http.Response response =
      await http.post("http://localhost:8888/auth/token",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": "Basic $clientCredentials"
          },
          body: body);
  print(response.body);
}
```

You can execute that code or you can use the following `curl`:

```text
curl -X POST http://localhost:8888/auth/token -H 'Authorization: Basic Y29tLmhlcm9lcy50dXRvcmlhbDo=' -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=bob&password=password&grant_type=password'
```

If you were successful, you'll get the following response containing an access token:

```text
{"access_token":"687PWKFHRTQ9MveQ2dKvP95D4cWie1gh","token_type":"bearer","expires_in":86399}
```

Hang on to this access token, we'll use it in a moment.

## Setting up OAuth 2.0: Securing Routes

Now that we can create and authenticate users, we can protect our heroes from anonymous users by requiring an access token for hero requests. In `channel.dart`, link an `Authorizer` in the middle of the `/heroes` channel:

```dart
router
  .route('/heroes/[:id]')
  .link(() => Authorizer.bearer(authServer))
  .link(() => HeroesController(context));
```

An `Authorizer` protects a channel from unauthorized requests by validating the `Authorization` header of a request. When created with `Authorizer.bearer`, it ensures that the authorization header contains a valid access token. Restart your application and try and access the `/heroes` endpoint without including any authorization:

```text
curl -X GET --verbose http://localhost:8888/heroes
```

You'll get a 401 Unauthorized response. Now, include your access token in a bearer authorization header \(note that your token will be different\):

```text
curl -X GET http://localhost:8888/heroes -H 'Authorization: Bearer 687PWKFHRTQ9MveQ2dKvP95D4cWie1gh'
```

You'll get back your list of heroes!

!!! note "Other Uses of Authorizer" An `Authorizer` can validate access token scopes and basic authorization credentials. You'll see examples of these in a later exercise.

