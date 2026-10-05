import Config

config :git_ops,
  mix_project: Mix.Project.get!(),
  repository_url: "https://github.com/lukad/ballast",
  types: [tidbit: [hidden?: true], important: [header: "Important Changes"]],
  github_handle_lookup?: true,
  version_tag_prefix: "v",
  manage_mix_version?: true,
  manage_readme_version: true
