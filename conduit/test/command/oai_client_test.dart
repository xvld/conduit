// ignore: unnecessary_const
@Tags(const ["cli"])
import 'package:fs_test_agent/dart_project_agent.dart';
import 'package:fs_test_agent/working_directory_agent.dart';
import 'package:test/test.dart';

import '../not_tests/cli_helpers.dart';

void main() {
  late CLIClient templateCli;
  late CLIClient projectUnderTestCli;

  setUpAll(() async {
    await CLIClient.activateCLI();
    final t =
        CLIClient(WorkingDirectoryAgent(DartProjectAgent.projectsDirectory));
    templateCli = await t.createTestProject(template: "db_and_auth");
    await templateCli.agent.getDependencies(offline: true);
  });

  setUp(() {
    projectUnderTestCli = templateCli.replicate(Uri.parse("replica/"));
  });

  tearDownAll(() async {
    await CLIClient.deactivateCLI();
    DartProjectAgent.tearDownAll();
  });

  test(
      "command with default args creates client page from current project dir pointing at localhost:8888",
      () async {
    await projectUnderTestCli.run("document", ["client"]);

    final clientContents =
        projectUnderTestCli.agent.getFile("client.html")?.readAsStringSync();
    expect(clientContents, contains('spec: {"openapi":"3.0.0"'));
    expect(
      clientContents,
      contains(
        '<script src="https://unpkg.com/swagger-ui-dist@3.12.1/swagger-ui-bundle.js"></script>',
      ),
    );

    // make sure auth urls were replaced
    expect(
      clientContents,
      contains('"authorizationUrl":"http://localhost:8888/auth/form"'),
    );
    expect(
      clientContents,
      contains('"tokenUrl":"http://localhost:8888/auth/token"'),
    );
    expect(
      clientContents,
      contains('"refreshUrl":"http://localhost:8888/auth/token"'),
    );
  });

  test("Replace relative urls with provided server", () async {
    await projectUnderTestCli
        .run("document", ["client", "--host", "https://server.com/v1/"]);

    final clientContents =
        projectUnderTestCli.agent.getFile("client.html")?.readAsStringSync();
    expect(clientContents, contains('spec: {"openapi":"3.0.0"'));
    expect(
      clientContents,
      contains(
        '<script src="https://unpkg.com/swagger-ui-dist@3.12.1/swagger-ui-bundle.js"></script>',
      ),
    );

    // make sure auth urls were replaced
    expect(
      clientContents,
      contains('"authorizationUrl":"https://server.com/v1/auth/form"'),
    );
  });
}
