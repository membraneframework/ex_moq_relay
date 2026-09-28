# :httpc in the relay tests needs :inets and, for its default TLS options even
# over plain HTTP, :ssl. Neither is a dependency, so Mix prunes them from the
# code path unless asked for.
Mix.ensure_application!(:inets)
Mix.ensure_application!(:ssl)
{:ok, _apps} = Application.ensure_all_started(:inets)
ExUnit.start(exclude: [:relay])
