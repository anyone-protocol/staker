job "hodler-deploy-stage-sepolia" {
    datacenters = ["ator-fin"]
    type = "batch"

    reschedule {
        attempts = 0
    }

    task "deploy-hodler-stage-task" {
        driver = "docker"

        config {
            network_mode = "host"
            image = "ghcr.io/anyone-protocol/hodler:0.4.20"
            entrypoint = ["npx"]
            command = "hardhat"
            args = ["run", "--network", "sepolia", "scripts/deploy.ts"]
        }

        vault {
            policies = ["hodler-sepolia-stage"]
        }

        template {
            data = <<EOH
            {{with secret "kv/hodler/sepolia/stage"}}
                hodler_DEPLOYER_KEY="{{.Data.data.hodler_DEPLOYER_KEY}}"
                CONSUL_TOKEN="{{.Data.data.CONSUL_TOKEN}}"
                JSON_RPC="{{.Data.data.JSON_RPC}}"
                hodler_OPERATOR_ADDRESS="{{.Data.data.hodler_OPERATOR_ADDRESS}}"
            {{end}}
            EOH
            destination = "secrets/file.env"
            env         = true
        }

        env {
            PHASE="stage"
            CONSUL_IP="127.0.0.1"
            CONSUL_PORT="8500"
            hodler_CONSUL_KEY="hodler/sepolia/stage/address"
            ATOR_TOKEN_CONSUL_KEY="ator-token/sepolia/stage/address"
        }

        restart {
            attempts = 0
            mode = "fail"
        }

        resources {
            cpu    = 4096
            memory = 4096
        }
    }
}
