<?php
/**
 * Custom Adminer entry point.
 *
 * - Restricts the available database drivers to PostgreSQL only.
 * - Sets a custom application name (browser tab + headings).
 *
 * This file replaces the default /var/www/html/index.php shipped with the
 * adminer:latest Docker image. It is mounted via a Docker Swarm config.
 */

namespace Adminer;

function adminer_object()
{
    class AdminerPostgresOnly extends Adminer
    {
        public function name()
        {
            return 'PostgreSQL Cluster Admin';
        }

        public function loginForm()
        {
            // Restrict the driver dropdown to PostgreSQL only.
            global $drivers;
            $drivers = ["pgsql" => "PostgreSQL"];
            parent::loginForm();
        }
    }

    return new AdminerPostgresOnly();
}

include './adminer.php';
